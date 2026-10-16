// =============================================================================
// SHE V3 — Offline automations (create a schedule with the cloud down)
// =============================================================================
// The device runs time-based schedules entirely on its own (firmware
// schedule_store.c: NVS + SNTP + a 5 s tick), so a SCHEDULE automation can be
// made to work with NO cloud at all. This service:
//
//   1. tries the cloud first — the normal path;
//   2. when the link is down AND the automation is expressible as a device-local
//      schedule (exactly one action, a plain HH:MM + day-of-week cron), writes it
//      to the BOARD over local control so it starts working immediately, and
//      persists the create payload in Hive;
//   3. replays those payloads to the cloud on reconnect, so the rule also exists
//      server-side and survives a reinstall.
//
// The device-local copy is deliberately KEPT after the cloud accepts the rule:
// that copy is what keeps the schedule running through the NEXT cloud outage,
// which is the whole point. Both paths drive absolute ON/OFF, so the worst case
// is a harmless duplicate command in the same minute. (The firmware's
// schedule_add is idempotent on content, so a cloud push converges on one slot.)
//
// What CANNOT go local, and is refused with a clear message rather than silently
// dropped: NODE_STATE and SOLAR triggers, multi-action rules, and cron shapes the
// device cannot express (day-of-month/month constraints, or a step/range in the
// hour or minute field). The device stores at most 8 schedules.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../../features/automations/automation_service.dart';
import '../local/local_control_service.dart';
import '../network/ws_client.dart';

/// Hive box holding automations created while offline, awaiting cloud sync.
/// Opened in main().
const String pendingAutomationsBox = 'pending_automations';

final offlineAutomationServiceProvider =
    Provider<OfflineAutomationService>((ref) => OfflineAutomationService(ref));

/// How a save ended up.
enum AutomationSaveOutcome {
  /// Stored in the cloud — the normal path.
  cloud,

  /// The cloud was unreachable, so the rule was written to the board and queued
  /// for sync.
  device,

  /// Offline, and this rule is not expressible as a device-local schedule.
  notExpressible,

  /// Offline and the board could not take it either.
  failed,
}

/// An automation created or edited offline, waiting to be pushed to the cloud.
class PendingAutomation {
  final String id;
  final String homeId;

  /// The exact request body for the cloud API, so the replay needs no
  /// re-derivation.
  final Map<String, dynamic> body;

  /// Null for a CREATE (POST); the automation id for an EDIT (PUT).
  ///
  /// Edits are queued too: the wizard's Edit path used to go straight to the
  /// cloud, so saving an existing automation with no connection died on a 10 s
  /// Dio timeout instead of being applied locally.
  final String? updateId;

  /// The device-local schedule slot we wrote (kept for diagnostics).
  final int boardIndex;
  final String label;
  final DateTime createdAt;

  const PendingAutomation({
    required this.id,
    required this.homeId,
    required this.body,
    required this.boardIndex,
    required this.label,
    required this.createdAt,
    this.updateId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'homeId': homeId,
        'body': body,
        if (updateId != null) 'updateId': updateId,
        'boardIndex': boardIndex,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
      };

  factory PendingAutomation.fromJson(Map<String, dynamic> j) => PendingAutomation(
        id: j['id']?.toString() ?? '',
        homeId: j['homeId']?.toString() ?? '',
        body: (j['body'] as Map?)?.cast<String, dynamic>() ?? const {},
        updateId: j['updateId']?.toString(),
        boardIndex: (j['boardIndex'] as num?)?.toInt() ?? -1,
        label: j['label']?.toString() ?? 'Automation',
        createdAt:
            DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
      );
}

class OfflineAutomationService {
  OfflineAutomationService(this.ref);
  final Ref ref;

  bool _flushing = false;

  Box get _box => Hive.box(pendingAutomationsBox);

  /// Automations created offline that still need to reach the cloud.
  List<PendingAutomation> pending() {
    final out = <PendingAutomation>[];
    for (final k in _box.keys) {
      final v = _box.get(k);
      if (v is Map) {
        out.add(PendingAutomation.fromJson(v.cast<String, dynamic>()));
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  /// Parse a 5-field cron into the board's `{hour, minute, days_mask}`, or null
  /// when the device cannot express it.
  ///
  /// The editor's picker produces `"<min> <hour> * * <dayField>"`, so this accepts
  /// exactly that shape: plain numbers for minute/hour, `*` for day-of-month and
  /// month, and a day-of-week field of `*`, single days, ranges and lists.
  static ({int hour, int minute, int daysMask})? scheduleFromCron(String cron) {
    final f = cron.trim().split(RegExp(r'\s+'));
    if (f.length != 5) return null;
    if (f[2] != '*' || f[3] != '*') return null; // day-of-month / month
    final minute = int.tryParse(f[0]);
    final hour = int.tryParse(f[1]);
    if (minute == null || minute < 0 || minute > 59) return null;
    if (hour == null || hour < 0 || hour > 23) return null;
    final mask = daysMaskFromCronField(f[4]);
    if (mask == null) return null;
    return (hour: hour, minute: minute, daysMask: mask);
  }

  /// `*` → daily; otherwise single days / ranges / lists.
  /// Bit0 = Sunday, matching both cron's 0=Sunday and the firmware's mask.
  static int? daysMaskFromCronField(String field) {
    if (field == '*') return 0x7F;
    var mask = 0;
    for (final part in field.split(',')) {
      if (part.isEmpty) return null;
      final dash = part.indexOf('-');
      int a, b;
      if (dash > 0) {
        a = int.tryParse(part.substring(0, dash)) ?? -1;
        b = int.tryParse(part.substring(dash + 1)) ?? -1;
      } else {
        a = b = int.tryParse(part) ?? -1;
      }
      if (a < 0 || a > 6 || b < 0 || b > 6 || b < a) return null;
      for (var d = a; d <= b; d++) {
        mask |= 1 << d;
      }
    }
    return mask == 0 ? null : mask;
  }

  /// Reduce a trigger + actions to a device-local schedule, or null when it
  /// cannot be expressed on the board.
  ({String deviceName, int hour, int minute, int daysMask, bool on})?
      asLocalSchedule(
    Map<String, Object> trigger,
    List<AutomationActionDraft> actions,
  ) {
    if ((trigger['type'] as String?) != 'SCHEDULE') return null;
    // The board holds ONE relay action per schedule.
    if (actions.length != 1) return null;
    final a = actions.single;
    if (a.deviceName.isEmpty) return null;
    final power = a.params['Power'];
    if (power is! bool) return null;
    final s = scheduleFromCron((trigger['cron'] ?? '').toString());
    if (s == null) return null;
    return (
      deviceName: a.deviceName,
      hour: s.hour,
      minute: s.minute,
      daysMask: s.daysMask,
      on: power,
    );
  }

  /// Create an automation: cloud first, device-local when offline.
  Future<({AutomationSaveOutcome outcome, String message})> create({
    required String homeId,
    required String name,
    required Map<String, Object> trigger,
    required List<AutomationActionDraft> actions,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'enabled': true,
      'trigger': trigger,
      'actions': [for (final a in actions) a.toJson()],
    };

    // ---- 1. Cloud first: the normal path. ----
    if (ref.read(wsConnectedProvider)) {
      try {
        await ref.read(automationServiceProvider).createAutomationRaw(homeId, body);
        return (outcome: AutomationSaveOutcome.cloud, message: 'Automation saved');
      } catch (_) {
        // Fall through — the link may have died mid-request.
      }
    }

    // ---- 2. Offline: only a single-action SCHEDULE can run on the board. ----
    final local = asLocalSchedule(trigger, actions);
    if (local == null) {
      return (
        outcome: AutomationSaveOutcome.notExpressible,
        message: 'With no connection the device can only run a single '
            '"turn one device on or off at a time" schedule. Reconnect to save '
            'this one.',
      );
    }

    final svc = ref.read(localControlServiceProvider);
    final channel = await svc.deviceChannel(local.deviceName);
    if (channel == null) {
      final why = svc.lastError ?? 'device not found on the board';
      return (
        outcome: AutomationSaveOutcome.failed,
        message: 'Could not reach ${local.deviceName} to store the schedule: $why',
      );
    }

    final index = await svc.addSchedule(
      hour: local.hour,
      minute: local.minute,
      daysMask: local.daysMask,
      relay: channel,
      on: local.on,
    );
    if (index == null) {
      final why = svc.lastError ?? 'the board refused it';
      return (
        outcome: AutomationSaveOutcome.failed,
        message: 'The device could not store the schedule: $why',
      );
    }

    final p = PendingAutomation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      homeId: homeId,
      body: body,
      boardIndex: index,
      label: name,
      createdAt: DateTime.now(),
    );
    await _box.put(p.id, p.toJson());

    return (
      outcome: AutomationSaveOutcome.device,
      message: 'Saved on the device — it runs without the cloud and will sync '
          'when you are back online.',
    );
  }

  /// Edit an automation: cloud first, device-local when offline.
  ///
  /// The wizard's Edit path used to go straight to the cloud, so saving an
  /// existing automation with no connection died on a 10 s Dio timeout.
  Future<({AutomationSaveOutcome outcome, String message})> update({
    required Automation existing,
    required String homeId,
    required String name,
    required Map<String, Object> trigger,
    required List<AutomationActionDraft> actions,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'trigger': trigger,
      'actions': [for (final a in actions) a.toJson()],
    };

    // ---- 1. Cloud first. ----
    if (ref.read(wsConnectedProvider)) {
      try {
        await ref
            .read(automationServiceProvider)
            .updateAutomationRaw(existing.id, body);
        return (outcome: AutomationSaveOutcome.cloud, message: 'Automation saved');
      } catch (_) {
        // Fall through — the link may have died mid-request.
      }
    }

    // ---- 2. Offline: only a single-action SCHEDULE can run on the board. ----
    final local = asLocalSchedule(trigger, actions);
    if (local == null) {
      return (
        outcome: AutomationSaveOutcome.notExpressible,
        message: 'With no connection the device can only run a single '
            '"turn one device on or off at a time" schedule. Reconnect to save '
            'this change.',
      );
    }

    final svc = ref.read(localControlServiceProvider);

    // Drop the device-local copy of the OLD rule first — otherwise it keeps
    // firing alongside the new one.
    await _removeLocalScheduleFor(existing, svc);

    // Also drop the copy written by a PREVIOUS offline edit of this same
    // automation. `_removeLocalScheduleFor` matches against `existing.trigger`,
    // which still holds the CLOUD's old value — a local edit never updates it —
    // so editing twice offline used to leave BOTH schedules on the board and
    // fire twice.
    for (final prev in pending()) {
      if (prev.updateId == existing.id && prev.boardIndex >= 0) {
        await svc.removeSchedule(prev.boardIndex);
        await _box.delete(prev.id);
      }
    }

    final channel = await svc.deviceChannel(local.deviceName);
    if (channel == null) {
      final why = svc.lastError ?? 'device not found on the board';
      return (
        outcome: AutomationSaveOutcome.failed,
        message: 'Could not reach ${local.deviceName} to store the schedule: $why',
      );
    }

    final index = await svc.addSchedule(
      hour: local.hour,
      minute: local.minute,
      daysMask: local.daysMask,
      relay: channel,
      on: local.on,
    );
    if (index == null) {
      final why = svc.lastError ?? 'the board refused it';
      return (
        outcome: AutomationSaveOutcome.failed,
        message: 'The device could not store the schedule: $why',
      );
    }

    final p = PendingAutomation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      homeId: homeId,
      body: body,
      updateId: existing.id,
      boardIndex: index,
      label: name,
      createdAt: DateTime.now(),
    );
    await _box.put(p.id, p.toJson());

    return (
      outcome: AutomationSaveOutcome.device,
      message: 'Saved on the device — it runs without the cloud and will sync '
          'when you are back online.',
    );
  }

  /// Remove the device-local schedule mirroring [a]'s OLD rule, if one exists.
  Future<void> _removeLocalScheduleFor(
      Automation a, LocalControlService svc) async {
    final actions = <AutomationActionDraft>[
      for (final r in a.rules)
        if (r.type == 'WRITE_PARAM')
          AutomationActionDraft(
            nodeId: r.config['node_id']?.toString() ?? '',
            deviceName: r.config['device_name']?.toString() ?? '',
            nodeDeviceId: r.config['node_device_id']?.toString() ?? '',
            params: {'Power': (r.config['params'] as Map?)?['Power'] == true},
          ),
    ];
    final old = asLocalSchedule(a.trigger.cast<String, Object>(), actions);
    if (old == null) return;

    final channel = await svc.deviceChannel(old.deviceName);
    if (channel == null) return;
    final list = await svc.listSchedules();
    if (list == null) return;

    for (final s in list) {
      if (s['hour'] == old.hour &&
          s['minute'] == old.minute &&
          s['days_mask'] == old.daysMask &&
          s['relay'] == channel &&
          s['action'] == (old.on ? 1 : 0)) {
        final idx = s['index'];
        if (idx is num) await svc.removeSchedule(idx.toInt());
      }
    }
  }

  /// Push offline-created automations to the cloud. Returns how many landed.
  /// Safe to call on every reconnect — entries are removed as they succeed and a
  /// re-entrancy guard stops a double POST.
  Future<int> flushPending() async {
    if (_flushing) return 0;
    if (!ref.read(wsConnectedProvider)) return 0;
    final items = pending();
    if (items.isEmpty) return 0;

    _flushing = true;
    var ok = 0;
    try {
      for (final p in items) {
        try {
          final svc = ref.read(automationServiceProvider);
          // An EDIT replays as a PUT; a CREATE as a POST.
          if (p.updateId != null) {
            await svc.updateAutomationRaw(p.updateId!, p.body);
          } else {
            await svc.createAutomationRaw(p.homeId, p.body);
          }
          // Deliberately KEEP the device-local schedule — see the file header.
          await _box.delete(p.id);
          ok++;
        } catch (_) {
          // Leave it in the box for the next reconnect.
        }
      }
    } finally {
      _flushing = false;
    }
    return ok;
  }
}
