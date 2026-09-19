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
import '../scenes/scene_service.dart' show homeDevicesProvider, SceneDeviceOption;

final automationServiceProvider =
    Provider<AutomationService>((ref) => AutomationService(ref));

/// Trigger types offered by the editor.
enum AutomationTriggerType { manual, schedule, nodeState }

extension AutomationTriggerTypeX on AutomationTriggerType {
  String get wireName {
    switch (this) {
      case AutomationTriggerType.manual:
        return 'MANUAL';
      case AutomationTriggerType.schedule:
        return 'SCHEDULE';
      case AutomationTriggerType.nodeState:
        return 'NODE_STATE';
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

  const Automation({
    required this.id,
    required this.homeId,
    required this.name,
    this.description,
    required this.enabled,
    required this.trigger,
    required this.rules,
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
      );

  String get triggerLabel {
    final type = trigger['type'] as String? ?? 'MANUAL';
    if (type == 'SCHEDULE') {
      return 'Schedule · cron "${trigger['cron'] ?? ''}"';
    }
    if (type == 'NODE_STATE') {
      return 'When ${trigger['device_name'] ?? 'device'}.'
          '${trigger['param_name'] ?? ''} '
          '${trigger['comparator'] ?? '=='} ${trigger['value']}';
    }
    return 'Manual';
  }

  int get ruleCount => rules.length;

  String? get cron => trigger['cron'] as String?;

  AutomationTriggerType get triggerType {
    final type = trigger['type'] as String? ?? 'MANUAL';
    if (type == 'SCHEDULE') return AutomationTriggerType.schedule;
    if (type == 'NODE_STATE') return AutomationTriggerType.nodeState;
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
  final Map<String, Object> params;

  const AutomationActionDraft({
    required this.nodeId,
    required this.deviceName,
    required this.params,
  });

  Map<String, dynamic> toJson() => {
        'type': 'WRITE_PARAM',
        'node_id': nodeId,
        'device_name': deviceName,
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

  /// PUT /automations/{id}
  Future<Automation> updateAutomation(
    String id, {
    String? name,
    String? description,
  }) async {
    final response = await _dio.put(
      ApiConstants.automation(id),
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      },
    );
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
