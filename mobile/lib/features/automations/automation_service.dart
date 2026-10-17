// =============================================================================
// SHE V3 — Automation service (Riverpod provider)
// =============================================================================
// V3-API-SPECIFICATION §7. Backend: AutomationController / AutomationService.
//
// Triggers: MANUAL, SCHEDULE {cron}, NODE_STATE {node_id, device_name,
// param_name, comparator, value}.
// Actions:  WRITE_PARAM {node_id, device_name, params},
//           ACTIVATE_SCENE {scene_id}, NOTIFICATION {category, title, body}.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';
import '../../core/offline/automation_snapshot.dart';
import '../scenes/scene_service.dart' show homeDevicesProvider, SceneDeviceOption;

final automationServiceProvider =
    Provider<AutomationService>((ref) => AutomationService(ref));

/// Automations for a home.
///
/// 🔴 LIVES HERE, NOT IN automations_screen.dart (bugfix 2026-10-08).
/// It used to be declared in the list screen, which meant ONLY that screen could
/// invalidate it. The detail screen could save an edit and had no way to tell
/// the list, so going back showed the OLD name / trigger / actions and the edit
/// looked like it had not happened. Both screens now share this one provider.
///
/// Snapshots to Hive so the tab survives an outage — without it the whole screen
/// (including the "Create Automation" pill) was replaced by an error offline.
final homeAutomationsProvider =
    FutureProvider.family<List<Automation>, String>((ref, homeId) async {
  try {
    final list =
        await ref.read(automationServiceProvider).listAutomations(homeId);
    await writeAutomationSnapshot(
        homeId, [for (final a in list) a.toJson()]);
    return list;
  } catch (_) {
    final cached = readAutomationSnapshot(homeId);
    if (cached != null) {
      return [
        for (final j in cached)
          if (j['id'] != null) Automation.fromJson(j),
      ];
    }
    rethrow;
  }
});

/// Trigger types offered by the editor.
enum AutomationTriggerType { manual, schedule, nodeState, location }

extension AutomationTriggerTypeX on AutomationTriggerType {
  String get wireName {
    switch (this) {
      case AutomationTriggerType.manual:
        return 'MANUAL';
      case AutomationTriggerType.schedule:
        return 'SCHEDULE';
      case AutomationTriggerType.nodeState:
        return 'NODE_STATE';
      case AutomationTriggerType.location:
        return 'LOCATION';
    }
  }

  String get label {
    switch (this) {
      case AutomationTriggerType.manual:
        return 'Manual (tap to run)';
      case AutomationTriggerType.schedule:
        return 'Schedule';
      case AutomationTriggerType.nodeState:
        return 'When a device changes';
      case AutomationTriggerType.location:
        return 'Location';
    }
  }
}

/// A stored automation as returned by the API.
class Automation {
  final String id;
  final String homeId;
  final String name;
  final String? description;
  final bool enabled;
  final Map<String, dynamic> trigger;
  final List<AutomationRule> rules;

  /// When the scheduler last actually fired this rule, or null if it never has.
  ///
  /// The backend has always tracked this; it just was not returned. Without it a
  /// rule that saves but never fires looks identical to one that fires and whose
  /// action fails — both simply "do nothing", with nothing on screen to tell them
  /// apart.
  final DateTime? lastFiredAt;

  const Automation({
    required this.id,
    required this.homeId,
    required this.name,
    this.description,
    required this.enabled,
    required this.trigger,
    required this.rules,
    this.lastFiredAt,
  });

  factory Automation.fromJson(Map<String, dynamic> json) => Automation(
        id: json['id'] as String,
        homeId: json['homeId'] as String? ?? '',
        name: json['name'] as String? ?? 'Automation',
        description: json['description'] as String?,
        enabled: json['enabled'] as bool? ?? false,
        trigger:
            Map<String, dynamic>.from(json['trigger'] as Map? ?? const {}),
        rules: (json['actions'] as List<dynamic>? ?? [])
            .map((a) => AutomationRule.fromJson(a as Map<String, dynamic>))
            .toList(),
        lastFiredAt: DateTime.tryParse(json['lastFiredAt']?.toString() ?? '')
            ?.toLocal(),
      );

  /// Round-trips through [fromJson], so a cached copy behaves like a fetched one.
  Map<String, dynamic> toJson() => {
        'id': id,
        'homeId': homeId,
        'name': name,
        if (description != null) 'description': description,
        'enabled': enabled,
        'trigger': trigger,
        'actions': [
          for (final r in rules) {'type': r.type, 'config': r.config},
        ],
        if (lastFiredAt != null) 'lastFiredAt': lastFiredAt!.toIso8601String(),
      };

  /// Human-readable "has this run?" line for the list.
  String get lastRunLabel {
    final at = lastFiredAt;
    if (at == null) return 'Never run yet';
    final now = DateTime.now();
    final diff = now.difference(at);
    if (diff.inMinutes < 1) return 'Ran just now';
    if (diff.inMinutes < 60) return 'Ran ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Ran ${diff.inHours}h ago';
    return 'Ran ${diff.inDays}d ago';
  }

  String get triggerLabel {
    final type = trigger['type'] as String? ?? 'MANUAL';
    if (type == 'SCHEDULE') {
      return 'Schedule · cron "${trigger['cron'] ?? ''}"';
    }
    // SOLAR is its own stored type; without this branch it fell through to
    // "Manual" and a sunrise/sunset rule read as a tap-to-run rule.
    if (type == 'SOLAR') {
      final event = (trigger['event'] ?? 'sunrise').toString().toLowerCase();
      return 'At ${event == 'sunset' ? 'sunset' : 'sunrise'}, every day';
    }
    if (type == 'NODE_STATE') {
      return 'When ${trigger['device_name'] ?? 'device'}.'
          '${trigger['param_name'] ?? ''} '
          '${trigger['comparator'] ?? '=='} ${trigger['value']}';
    }
    return 'Manual';
  }

  /// True for a sunrise/sunset trigger. Kept separate from [triggerType], which
  /// collapses SOLAR into `manual` and is therefore wrong for filtering.
  bool get isSolar => trigger['type'] == 'SOLAR';

  /// True when the rule runs on a clock (fixed cron OR solar). Used by the
  /// "Scheduled" filter so solar rules are not hidden from it.
  bool get isTimeBased =>
      triggerType == AutomationTriggerType.schedule || isSolar;

  int get ruleCount => rules.length;

  String? get cron => trigger['cron'] as String?;

  AutomationTriggerType get triggerType {
    final type = trigger['type'] as String? ?? 'MANUAL';
    if (type == 'SCHEDULE' || type == 'SOLAR') {
      return AutomationTriggerType.schedule;
    }
    if (type == 'NODE_STATE') return AutomationTriggerType.nodeState;
    if (type == 'LOCATION') return AutomationTriggerType.location;
    return AutomationTriggerType.manual;
  }
}

/// One action row of an automation.
class AutomationRule {
  final String type;
  final Map<String, dynamic> config;

  const AutomationRule({required this.type, required this.config});

  factory AutomationRule.fromJson(Map<String, dynamic> json) => AutomationRule(
        type: json['type'] as String? ?? '',
        config: Map<String, dynamic>.from(json['config'] as Map? ?? const {}),
      );
}

/// Result of firing an automation.
class AutomationTriggerResult {
  final int executed;
  final List<String> failed;

  const AutomationTriggerResult(
      {required this.executed, required this.failed});

  bool get isFullSuccess => failed.isEmpty;
}

/// An action being authored in the editor (WRITE_PARAM only for now —
/// ACTIVATE_SCENE and NOTIFICATION have no editor UI yet).
class AutomationActionDraft {
  final String nodeId;
  final String deviceName;

  /// Stable device UUID. The backend resolves by this when present, falling
  /// back to `device_name` for legacy rows — so a rename never orphans the rule.
  final String nodeDeviceId;
  final Map<String, Object> params;

  const AutomationActionDraft({
    required this.nodeId,
    required this.deviceName,
    required this.params,
    this.nodeDeviceId = '',
  });

  Map<String, dynamic> toJson() => {
        'type': 'WRITE_PARAM',
        'node_id': nodeId,
        'device_name': deviceName,
        if (nodeDeviceId.isNotEmpty) 'node_device_id': nodeDeviceId,
        'params': params,
      };
}

class AutomationService {
  final Ref ref;
  AutomationService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  /// GET /homes/{homeId}/automations
  Future<List<Automation>> listAutomations(String homeId) async {
    final response = await _dio.get(ApiConstants.homeAutomations(homeId));
    final list = response.data['data'] as List<dynamic>? ?? [];
    return list
        .map((a) => Automation.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// POST /homes/{homeId}/automations
  Future<Automation> createAutomation(
    String homeId, {
    required String name,
    String? description,
    required Map<String, Object> trigger,
    List<AutomationActionDraft> actions = const [],
  }) async {
    final response = await _dio.post(
      ApiConstants.homeAutomations(homeId),
      data: {
        'name': name,
        if (description != null) 'description': description,
        'enabled': true,
        'trigger': trigger,
        'actions': actions.map((a) => a.toJson()).toList(),
      },
    );
    return Automation.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// POST /homes/{homeId}/automations with an already-built body.
  ///
  /// Used to replay an automation that was created while offline — the payload was
  /// stored verbatim in Hive (see OfflineAutomationService), so re-deriving it from
  /// typed arguments would risk drifting from what the user actually saw.
  Future<Automation> createAutomationRaw(
      String homeId, Map<String, dynamic> body) async {
    final response = await _dio.post(
      ApiConstants.homeAutomations(homeId),
      data: body,
    );
    return Automation.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// PUT /automations/{id}
  ///
  /// `trigger` / `actions` are optional and REPLACE the stored rule when sent —
  /// without them the editor could only rename an automation, not change what
  /// it does.
  Future<Automation> updateAutomation(
    String id, {
    String? name,
    String? description,
    Map<String, Object>? trigger,
    List<AutomationActionDraft>? actions,
  }) async {
    final response = await _dio.put(
      ApiConstants.automation(id),
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (trigger != null) 'trigger': trigger,
        if (actions != null) 'actions': actions.map((a) => a.toJson()).toList(),
      },
    );
    return Automation.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// PUT /automations/{id} with an already-built body.
  ///
  /// Used to replay an EDIT made while offline — the payload was stored verbatim
  /// in Hive (see OfflineAutomationService).
  Future<Automation> updateAutomationRaw(
      String id, Map<String, dynamic> body) async {
    final response = await _dio.put(ApiConstants.automation(id), data: body);
    return Automation.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// PATCH /automations/{id}/enabled
  Future<Automation> setEnabled(String id, bool enabled) async {
    final response = await _dio.patch(
      ApiConstants.automationEnabled(id),
      data: {'enabled': enabled},
    );
    return Automation.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// DELETE /automations/{id} — 204, soft delete.
  Future<void> deleteAutomation(String id) async {
    await _dio.delete(ApiConstants.automation(id));
  }

  /// POST /automations/{id}/trigger — run the actions now.
  Future<AutomationTriggerResult> trigger(String id) async {
    final response = await _dio.post(ApiConstants.automationTrigger(id));
    final data = response.data['data'] as Map<String, dynamic>;
    return AutomationTriggerResult(
      executed: data['executed'] as int? ?? 0,
      failed: (data['failed'] as List<dynamic>? ?? [])
          .map((f) => f.toString())
          .toList(),
    );
  }

  /// Devices available as NODE_STATE sources / action targets.
  Future<List<SceneDeviceOption>> devices(String homeId) =>
      ref.read(homeDevicesProvider(homeId).future);
}
