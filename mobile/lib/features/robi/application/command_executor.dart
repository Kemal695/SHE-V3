// =============================================================================
// SHE V3 — Command executor (Plan §3 "CommandExecutor")
// =============================================================================
// The ONLY place voice commands reach the existing SHE device services. It
// parses the transcript against the current home and dispatches through the
// same offline-tolerant, queue-aware path a manual toggle uses.
//
// It owns no recognition and no dialogue state — those live in HandleUtterance
// and VoiceSession.
// =============================================================================

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/ws_client.dart' show wsConnectedProvider;
import '../../../core/offline/command_queue.dart';
import '../../../core/offline/device_snapshot.dart';
import '../../../core/offline/group_snapshot.dart';
import '../../../core/offline/automation_snapshot.dart';
import '../../../features/device_detail/device_detail_screen.dart'
    show nodeDeviceParamsProvider;
import '../../../features/device_detail/node_service.dart';
import '../../../features/scenes/scene_service.dart';
import '../../../features/automations/automation_service.dart';

import '../data/custom_voice_store.dart';
import '../data/native_speech_provider.dart';
import '../data/voice_diagnostics.dart';
import '../domain/voice_command.dart';
import '../domain/custom_voice_command.dart';
import '../domain/command_result.dart';

/// The home context the voice pipeline parses and executes against.
typedef VoiceContext = ({
  List<VoiceDevice> devices,
  List<VoiceScene> scenes,
  List<VoiceGroup> groups,
  List<VoiceAutomation> automations,
  List<CustomVoiceCommand> customCommands,
});

class CommandExecutor {
  final Ref ref;
  CommandExecutor(this.ref);

  // Short-lived context cache (see loadContext). The voice path used to make
  // 5-6 SEQUENTIAL network calls (nodes, devices per node, groups, scenes,
  // automations) BEFORE it could act — that was most of the "Robi is slow"
  // latency. The lists change rarely, so 30 s is safe; custom commands are
  // local and always read fresh.
  // static: every CommandExecutor instance (VoiceService's, HandleUtterance's,
  // commandExecutorProvider's) shares one cache, so a preload on one warms the
  // others. The 30 s TTL bounds staleness.
  static VoiceContext? _ctxCache;
  static String? _ctxHomeId;
  static DateTime? _ctxAt;

  // ---- Context loading (mirrors the former VoiceService._loadContext) -----

  /// Load the home's devices and scenes as parser/executor inputs. Done fresh
  /// per utterance so a device renamed a moment ago is sayable immediately.
  Future<VoiceContext> loadContext(String homeId) async {
    final now = DateTime.now();
    final cached = _ctxCache;
    if (cached != null &&
        _ctxHomeId == homeId &&
        _ctxAt != null &&
        now.difference(_ctxAt!) < const Duration(seconds: 30)) {
      return (
        devices: cached.devices,
        scenes: cached.scenes,
        groups: cached.groups,
        automations: cached.automations,
        customCommands: ref.read(customCommandsProvider),
      );
    }

    final devices = <VoiceDevice>[];
    if (ref.read(wsConnectedProvider)) {
      try {
        final nodeService = ref.read(nodeServiceProvider);
        final nodes = await nodeService.listNodesByHome(homeId);
        for (final n in nodes) {
          final nodeId = n['id']?.toString();
          if (nodeId == null) continue;
          final list = await nodeService.listDevices(nodeId);
          for (final d in list) {
            final deviceId = d['id']?.toString();
            final name = d['device_name']?.toString();
            if (deviceId == null || name == null) continue;
            // Only switch-like devices respond to Power.
            final type = d['device_type']?.toString() ?? '';
            if (type.isNotEmpty && type != 'esp.device.switch') continue;
            final display = d['display_name']?.toString();
            devices.add(VoiceDevice(
              nodeId: nodeId,
              deviceId: deviceId,
              deviceName: name,
              displayName:
                  (display != null && display.trim().isNotEmpty) ? display : null,
            ));
          }
        }
      } catch (_) {
        devices.addAll(_devicesFromSnapshot(homeId));
      }
    } else {
      devices.addAll(_devicesFromSnapshot(homeId));
    }

    // Teach the recogniser the names the user actually says. Without this the
    // bias list holds only the firmware defaults ("socket one", "light two"),
    // and a renamed device ("Tv soket", "bedroom light") stays unrecognisable.
    addBiasPhrases([
      for (final d in devices) ...[d.deviceName, d.label],
    ]);

    final scenes = <VoiceScene>[];
    try {
      for (final s in await ref.read(sceneServiceProvider).listScenes(homeId)) {
        scenes.add(VoiceScene(id: s.id, name: s.name));
      }
    } catch (_) {
      // Scenes are optional; device control still works without them.
    }

    // User-defined groups (backend node_groups + node_group_members). Fetch
    // online and snapshot to Hive; read the snapshot offline so group commands
    // still work with no cloud link.
    final groups = <VoiceGroup>[];
    List<Map<String, dynamic>> rawGroups = const [];
    try {
      rawGroups = await ref.read(nodeServiceProvider).listDeviceGroups(homeId);
      if (rawGroups.isNotEmpty) await writeGroupSnapshot(homeId, rawGroups);
    } catch (_) {
      rawGroups = readGroupSnapshot(homeId) ?? const [];
    }
    for (final g in rawGroups) {
      final id = g['id']?.toString();
      final name = g['name']?.toString();
      if (id == null || name == null) continue;
      final rawIds =
          (g['device_ids'] ?? g['deviceIds']) as List<dynamic>? ?? const [];
      groups.add(VoiceGroup(
        id: id,
        name: name,
        deviceIds: rawIds.map((e) => e.toString()).toList(),
      ));
    }

    // Automations: homeAutomationsProvider already snapshots to Hive and falls
    // back to the cache offline.
    final automations = <VoiceAutomation>[];
    try {
      for (final a in await ref.read(homeAutomationsProvider(homeId).future)) {
        automations.add(
          VoiceAutomation(id: a.id, name: a.name, enabled: a.enabled),
        );
      }
    } catch (_) {
      final cached = readAutomationSnapshot(homeId);
      if (cached != null) {
        for (final j in cached) {
          final id = j['id']?.toString();
          final name = j['name']?.toString();
          if (id != null && name != null) {
            automations.add(VoiceAutomation(
              id: id,
              name: name,
              enabled: j['enabled'] == true,
            ));
          }
        }
      }
    }

    final ctx = (
      devices: devices,
      scenes: scenes,
      groups: groups,
      automations: automations,
      customCommands: ref.read(customCommandsProvider),
    );
    _ctxCache = ctx;
    _ctxHomeId = homeId;
    _ctxAt = now;
    return ctx;
  }

  /// Build the voice device list from the cached device snapshot — the offline
  /// substitute for the cloud listing.
  List<VoiceDevice> _devicesFromSnapshot(String homeId) {
    final out = <VoiceDevice>[];
    final rows = readDeviceSnapshot(homeId) ?? const <Map<String, dynamic>>[];
    for (final row in rows) {
      final raw = (row['raw'] as Map?)?.cast<String, dynamic>();
      final deviceId = row['deviceId']?.toString();
      final name = raw?['device_name']?.toString();
      if (deviceId == null || name == null) continue;
      final type = raw?['device_type']?.toString() ?? '';
      if (type.isNotEmpty && type != 'esp.device.switch') continue;
      final display = raw?['display_name']?.toString();
      out.add(VoiceDevice(
        nodeId: row['nodeId']?.toString() ?? '',
        deviceId: deviceId,
        deviceName: name,
        displayName:
            (display != null && display.trim().isNotEmpty) ? display : null,
      ));
    }
    return out;
  }

  // ---- Execution ----------------------------------------------------------

  /// Parse [transcript] against [homeId] and perform the resulting action,
  /// returning a structured [CommandResult].
  Future<CommandResult> executeTranscript(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
    required bool amharic,
  }) async {
    final ctx = await loadContext(homeId);
    final intent = parseVoiceIntent(
      transcript,
      devices: ctx.devices,
      scenes: ctx.scenes,
      groups: ctx.groups,
      automations: ctx.automations,
      customCommands: ctx.customCommands,
      latinDeviceTokens: latinDeviceTokens,
      amharic: amharic,
    );
    return _executeIntent(
      intent,
      transcript: transcript,
      ctx: ctx,
      latinDeviceTokens: latinDeviceTokens,
    );
  }

  Future<CommandResult> _executeIntent(
    VoiceIntent intent, {
    required String transcript,
    required VoiceContext ctx,
    required bool latinDeviceTokens,
  }) async {
    final nodeService = ref.read(nodeServiceProvider);

    switch (intent.action) {
      case VoiceAction.turnOn:
      case VoiceAction.turnOff:
        final targets = intent.devices;
        if (targets.isEmpty) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch which device.",
          );
        }
        final on = intent.action == VoiceAction.turnOn;
        // Same offline-tolerant path a manual toggle uses. Loops so a
        // multi-device command ("socket 1 and light 2") acts on every target.
        final queue = ref.read(commandQueueProvider.notifier);
        final wsUp = ref.read(wsConnectedProvider);
        var anyQueued = false;
        var queuedCount = 0;
        for (final device in targets) {
          final outcome = await queue.sendOrQueue(
            nodeId: device.nodeId,
            deviceId: device.deviceId,
            params: {'Power': on},
            label: '${device.label} · ${on ? 'On' : 'Off'}',
            deviceName: device.deviceName,
          );
          if (outcome == SendOutcome.queued) {
            anyQueued = true;
            queuedCount++;
          }
          // Keep every surface consistent with the write, exactly as the manual
          // toggle does. Skipped after a LOCAL send (cloud unreachable).
          if (wsUp) {
            ref.invalidate(nodeDeviceParamsProvider(
                '${device.nodeId}|${device.deviceId}'));
          }
        }
        // The log is the only place a "only two of three switched" report can be
        // told apart from a parse that only found two.
        VoiceLog.log('exec: ${on ? 'On' : 'Off'} '
            '${targets.length} target(s) queued=$queuedCount');
        return CommandResult(
          status: anyQueued ? CommandStatus.queued : CommandStatus.sent,
          intent: intent,
          message: '${on ? 'On' : 'Off'}: '
              '${targets.map((d) => d.label).join(', ')}'
              '${anyQueued ? ' (queued)' : ''}',
        );

      case VoiceAction.turnAllOn:
      case VoiceAction.turnAllOff:
        final on = intent.action == VoiceAction.turnAllOn;
        final group = intent.group ?? 'all';
        final nodes = <String>{};
        for (final d in ctx.devices) {
          if (_inGroup(d, group)) nodes.add(d.nodeId);
        }
        if (nodes.isEmpty) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: 'No ${_label(group)} found.',
          );
        }
        if (!ref.read(wsConnectedProvider)) {
          // Offline: no group endpoint. Command each matching device.
          var sent = 0;
          var queued = 0;
          for (final d in ctx.devices) {
            if (!_inGroup(d, group)) continue;
            final outcome = await ref
                .read(commandQueueProvider.notifier)
                .sendOrQueue(
                  nodeId: d.nodeId,
                  deviceId: d.deviceId,
                  params: {'Power': on},
                  label: '${d.label} · ${on ? 'On' : 'Off'}',
                  deviceName: d.deviceName,
                );
            if (outcome == SendOutcome.queued) {
              queued++;
            } else {
              sent++;
            }
          }
          return CommandResult(
            status: sent > 0 ? CommandStatus.sent : CommandStatus.queued,
            intent: intent,
            message: '${on ? 'On' : 'Off'}: all ${_label(group)}'
                '${sent > 0 ? ' ($sent)' : ''}'
                '${queued > 0 ? ' · $queued queued' : ''}',
          );
        }
        var total = 0;
        for (final nodeId in nodes) {
          final res = await nodeService.setGroup(nodeId, group, on);
          total += (res['applied'] as int?) ?? (res['count'] as int?) ?? 0;
        }
        return CommandResult(
          status: CommandStatus.sent,
          intent: intent,
          message: '${on ? 'On' : 'Off'}: all ${_label(group)}'
              '${total > 0 ? ' ($total)' : ''}',
        );

      case VoiceAction.activateScene:
        final sceneId = intent.sceneId;
        if (sceneId == null) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch the scene name.",
          );
        }
        final result = await ref.read(sceneServiceProvider).activate(sceneId);
        return CommandResult(
          status: result.isFullSuccess
              ? CommandStatus.sent
              : CommandStatus.sent,
          intent: intent,
          message: result.isFullSuccess
              ? 'Scene activated (${result.acceptedCount} actions)'
              : 'Scene partly applied — ${result.failed.join(', ')}',
        );

      case VoiceAction.turnOnGroup:
      case VoiceAction.turnOffGroup:
        final g = intent.deviceGroup;
        if (g == null) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch which group.",
          );
        }
        final groupOn = intent.action == VoiceAction.turnOnGroup;
        // Resolve the group's member device ids against the home's devices so
        // each one takes the same offline-tolerant send the master button uses.
        final members = <VoiceDevice>[];
        for (final id in g.deviceIds) {
          for (final d in ctx.devices) {
            if (d.deviceId == id) {
              members.add(d);
              break;
            }
          }
        }
        if (members.isEmpty) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: 'No devices in ${g.name}.',
          );
        }
        var groupSent = 0;
        var groupQueued = 0;
        for (final d in members) {
          final outcome = await ref
              .read(commandQueueProvider.notifier)
              .sendOrQueue(
                nodeId: d.nodeId,
                deviceId: d.deviceId,
                params: {'Power': groupOn},
                label: '${d.label} · ${groupOn ? 'On' : 'Off'}',
                deviceName: d.deviceName,
              );
          if (outcome == SendOutcome.queued) {
            groupQueued++;
          } else {
            groupSent++;
          }
        }
        return CommandResult(
          status: groupSent > 0 ? CommandStatus.sent : CommandStatus.queued,
          intent: intent,
          message: '${groupOn ? 'On' : 'Off'}: ${g.name}'
              '${groupSent > 0 ? ' ($groupSent)' : ''}'
              '${groupQueued > 0 ? ' · $groupQueued queued' : ''}',
        );

      case VoiceAction.runAutomation:
        final runAuto = intent.automation;
        if (runAuto == null) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch the automation name.",
          );
        }
        final ran =
            await ref.read(automationServiceProvider).trigger(runAuto.id);
        return CommandResult(
          status: CommandStatus.sent,
          intent: intent,
          message: ran.failed.isEmpty
              ? 'Ran ${runAuto.name} (${ran.executed} actions)'
              : 'Ran ${runAuto.name} — ${ran.failed.length} failed',
        );

      case VoiceAction.enableAutomation:
      case VoiceAction.disableAutomation:
        final toggleAuto = intent.automation;
        if (toggleAuto == null) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch the automation name.",
          );
        }
        final enable = intent.action == VoiceAction.enableAutomation;
        await ref
            .read(automationServiceProvider)
            .setEnabled(toggleAuto.id, enable);
        return CommandResult(
          status: CommandStatus.sent,
          intent: intent,
          message: '${enable ? 'Enabled' : 'Disabled'}: ${toggleAuto.name}',
        );

      case VoiceAction.queryState:
        return await _queryState(intent, ctx);

      case VoiceAction.setBrightness:
        final targets = intent.devices;
        final level = intent.level;
        if (targets.isEmpty || level == null) {
          return CommandResult(
            status: CommandStatus.rejected,
            intent: intent,
            message: "I didn't catch which light or how bright.",
          );
        }
        final queue = ref.read(commandQueueProvider.notifier);
        final wsUp = ref.read(wsConnectedProvider);
        var anyQueued = false;
        for (final d in targets) {
          final outcome = await queue.sendOrQueue(
            nodeId: d.nodeId,
            deviceId: d.deviceId,
            params: {'Brightness': level},
            label: '${d.label} · $level%',
            deviceName: d.deviceName,
          );
          if (outcome == SendOutcome.queued) anyQueued = true;
          if (wsUp) {
            ref.invalidate(
                nodeDeviceParamsProvider('${d.nodeId}|${d.deviceId}'));
          }
        }
        return CommandResult(
          status: anyQueued ? CommandStatus.queued : CommandStatus.sent,
          intent: intent,
          message: '${targets.map((d) => d.label).join(', ')} → $level%'
              '${anyQueued ? ' (queued)' : ''}',
        );

      case VoiceAction.unknown:
        return CommandResult(
          status: CommandStatus.rejected,
          intent: intent,
          message: "I heard \"$transcript\" but didn't understand it.",
        );
    }
  }

  /// Answer a state question from live device params. Never changes anything.
  Future<CommandResult> _queryState(
      VoiceIntent intent, VoiceContext ctx) async {
    final List<VoiceDevice> targets;
    final String scope;
    if (intent.devices.isNotEmpty) {
      targets = intent.devices;
      scope = targets.first.label;
    } else {
      final group = intent.group ?? 'all';
      targets = ctx.devices.where((d) => _inGroup(d, group)).toList();
      scope = _label(group);
    }
    if (targets.isEmpty) {
      return CommandResult(
        status: CommandStatus.rejected,
        intent: intent,
        message: 'No $scope found.',
      );
    }

    final on = <String>[];
    final off = <String>[];
    for (final d in targets) {
      final state = await _powerOf(d);
      if (state == null) {
        return CommandResult(
          status: CommandStatus.rejected,
          intent: intent,
          message: "I can't reach ${d.label} right now.",
        );
      }
      (state ? on : off).add(d.label);
    }

    final String message;
    if (targets.length == 1) {
      message = '${targets.first.label} is ${on.isEmpty ? 'off' : 'on'}.';
    } else if (on.isEmpty) {
      message = 'All $scope are off.';
    } else if (off.isEmpty) {
      message = 'All $scope are on.';
    } else {
      message = 'On: ${on.join(', ')}. Off: ${off.join(', ')}.';
    }
    return CommandResult(
      status: CommandStatus.sent,
      intent: intent,
      message: message,
    );
  }

  /// Current Power value of [d], or null when it cannot be read.
  Future<bool?> _powerOf(VoiceDevice d) async {
    try {
      final params = await ref.read(
        nodeDeviceParamsProvider('${d.nodeId}|${d.deviceId}').future,
      );
      for (final p in params) {
        if (p['param_name'] != 'Power') continue;
        final v = p['value'] ?? p['last_value'] ?? p['reported_value'];
        if (v is bool) return v;
        if (v is num) return v != 0;
        if (v is String) {
          final s = v.toLowerCase();
          return s == 'true' || s == '1';
        }
      }
    } catch (_) {}
    return null;
  }

  bool _inGroup(VoiceDevice d, String group) {
    final name = d.deviceName.toLowerCase();
    return switch (group) {
      'lights' => name.startsWith('light'),
      'sockets' => name.startsWith('socket'),
      _ => name.startsWith('light') || name.startsWith('socket'),
    };
  }

  String _label(String group) => switch (group) {
        'lights' => 'lights',
        'sockets' => 'sockets',
        _ => 'devices',
      };
}

/// Shared executor, so UI that needs the same context the voice pipeline loads
/// (the custom-command editor's target pickers) can reuse [loadContext].
final commandExecutorProvider =
    Provider<CommandExecutor>((ref) => CommandExecutor(ref));
