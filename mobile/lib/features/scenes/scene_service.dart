// =============================================================================
// SHE V3 — Scene service (Riverpod provider)
// =============================================================================
// V3-API-SPECIFICATION §8.1. Backend: SceneController / SceneService (V10 tables).
//
// Before this existed the dashboard rendered a hardcoded scene list and tapping a
// scene only showed a SnackBar — there was no API behind it at all.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';
import '../device_detail/node_service.dart';

final sceneServiceProvider = Provider<SceneService>((ref) => SceneService(ref));

/// Scenes for a home. Shared by the dashboard row and the scenes editor.
/// GET /api/v3/homes/{homeId}/scenes
final homeScenesProvider =
    FutureProvider.family<List<Scene>, String>(
  (ref, homeId) => ref.read(sceneServiceProvider).listScenes(homeId),
);

/// Writable devices for a home, flattened as (nodeId, deviceName) pairs so the
/// editor can offer a picker without caring about node structure.
final homeDevicesProvider =
    FutureProvider.family<List<SceneDeviceOption>, String>((ref, homeId) async {
  final nodes = await ref.read(nodeServiceProvider).listNodesByHome(homeId);
  final out = <SceneDeviceOption>[];
  for (final n in nodes) {
    final nodeId = n['id']?.toString();
    final nodeName = n['node_id']?.toString() ?? nodeId ?? 'node';
    if (nodeId == null) continue;
    final devices = await ref.read(nodeServiceProvider).listDevices(nodeId);
    for (final d in devices) {
      final name = d['device_name']?.toString();
      if (name == null) continue;
      out.add(SceneDeviceOption(
        nodeId: nodeId,
        nodeName: nodeName,
        deviceName: name,
        deviceType: d['device_type']?.toString() ?? '',
        deviceId: d['id']?.toString() ?? '',
        displayName: (d['display_name'] ?? d['displayName'] ?? '').toString(),
      ));
    }
  }
  return out;
});

/// One selectable device in the scene editor.
class SceneDeviceOption {
  final String nodeId;
  final String nodeName;
  final String deviceName;
  final String deviceType;

  /// The device's STABLE UUID (`node_devices.id`).
  ///
  /// Automations and scenes must reference a device by this, not by name: a
  /// rename otherwise leaves the stored `device_name` stale, and the rule stops
  /// finding its own device.
  final String deviceId;

  /// What the USER sees. Renaming a device writes `display_name` (the technical
  /// `device_name` is immutable), so anything user-facing must show this — using
  /// `deviceName` is why a renamed device kept showing its OLD name.
  final String displayName;

  const SceneDeviceOption({
    required this.nodeId,
    required this.nodeName,
    required this.deviceName,
    required this.deviceType,
    this.deviceId = '',
    this.displayName = '',
  });

  /// The user-facing name, falling back to the technical one.
  String get shownName => displayName.isNotEmpty ? displayName : deviceName;

  String get label => '$shownName · $nodeName';
  bool get isSwitch => deviceType == 'esp.device.switch';
}

/// A device resolved by its id, used to label scene actions.
///
/// Scene actions store only `nodeDeviceId` (a UUID) — the API returns no device
/// name with them — so the Scene Detail screen has to look names up itself.
class DeviceLookup {
  final String name;
  final String kind;
  final String nodeId;

  const DeviceLookup({
    required this.name,
    required this.kind,
    required this.nodeId,
  });
}

/// deviceId -> [DeviceLookup] for every device in a home.
///
/// Walks the home's nodes and their device lists. Mirrors the flattening the
/// Devices tab does, but keyed by device id because that is what a
/// [SceneAction] carries.
final homeDeviceLookupProvider =
    FutureProvider.family<Map<String, DeviceLookup>, String>(
  (ref, homeId) async {
    final out = <String, DeviceLookup>{};
    try {
      final nodes = await ref.read(nodeServiceProvider).listNodesByHome(homeId);
      for (final n in nodes) {
        final nodeId = n['id']?.toString();
        if (nodeId == null) continue;
        List<Map<String, dynamic>> devices;
        try {
          devices = await ref.read(nodeServiceProvider).listDevices(nodeId);
        } catch (_) {
          continue;
        }
        for (final d in devices) {
          final id = d['id']?.toString();
          if (id == null) continue;
          out[id] = DeviceLookup(
            name: d['display_name']?.toString() ??
                d['device_name']?.toString() ??
                'Device',
            kind: d['device_type']?.toString() ?? '',
            nodeId: nodeId,
          );
        }
      }
    } catch (_) {
      // A failure just means actions render with their raw id.
    }
    return out;
  },
);

/// A single scene by id — backs the Scene Detail screen.
///
/// Separate from [homeScenesProvider] so opening a detail page does not refetch
/// the whole home's scenes, and so a deep link works without one.
final sceneByIdProvider = FutureProvider.family<Scene?, String>(
  (ref, id) => ref.read(sceneServiceProvider).getScene(id),
);

/// A scene returned by the API. `actions` holds the individual device+param writes.
class Scene {
  final String id;
  final String homeId;
  final String name;
  final String? icon;
  final int sortOrder;
  final List<SceneAction> actions;

  const Scene({
    required this.id,
    required this.homeId,
    required this.name,
    this.icon,
    required this.sortOrder,
    required this.actions,
  });

  factory Scene.fromJson(Map<String, dynamic> json) => Scene(
        id: json['id'] as String,
        homeId: json['homeId'] as String,
        name: json['name'] as String? ?? 'Scene',
        icon: json['icon'] as String?,
        sortOrder: json['sortOrder'] as int? ?? 0,
        actions: (json['actions'] as List<dynamic>? ?? [])
            .map((a) => SceneAction.fromJson(a as Map<String, dynamic>))
            .toList(),
      );

  /// How many device writes this scene performs — shown as "N actions".
  int get actionCount => actions.length;
}

class SceneAction {
  final String nodeDeviceId;
  final String paramName;
  final Object? value;

  const SceneAction({
    required this.nodeDeviceId,
    required this.paramName,
    this.value,
  });

  factory SceneAction.fromJson(Map<String, dynamic> json) => SceneAction(
        nodeDeviceId: json['nodeDeviceId'] as String? ?? '',
        paramName: json['paramName'] as String? ?? '',
        value: json['value'],
      );
}

/// Result of activating a scene. One failed device does not abort the others.
class SceneActivationResult {
  final String executionId;
  final int acceptedCount;
  final List<String> failed;

  const SceneActivationResult({
    required this.executionId,
    required this.acceptedCount,
    required this.failed,
  });

  bool get isFullSuccess => failed.isEmpty;
}

/// A device+param write being authored in the editor.
/// Wire shape is snake_case (V3-API-SPECIFICATION §8.1).
class SceneActionDraft {
  final String nodeId;
  final String deviceName;
  final Map<String, Object> params;

  const SceneActionDraft({
    required this.nodeId,
    required this.deviceName,
    required this.params,
  });

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'device_name': deviceName,
        'params': params,
      };
}

class SceneService {
  final Ref ref;
  SceneService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  Future<List<Scene>> listScenes(String homeId) async {
    final response = await _dio.get(ApiConstants.homeScenes(homeId));
    final list = response.data['data'] as List<dynamic>? ?? [];
    return list
        .map((s) => Scene.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// GET /scenes/{id} — a single scene.
  ///
  /// Returns null on 404 rather than throwing, so the detail screen can show a
  /// "scene no longer exists" state (a deep link can outlive its scene).
  Future<Scene?> getScene(String id) async {
    try {
      final response = await _dio.get(ApiConstants.scene(id));
      final data = response.data['data'];
      if (data is! Map<String, dynamic>) return null;
      return Scene.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// POST /homes/{homeId}/scenes
  Future<Scene> createScene(
    String homeId, {
    required String name,
    String? icon,
    List<SceneActionDraft> actions = const [],
  }) async {
    final response = await _dio.post(
      ApiConstants.homeScenes(homeId),
      data: {
        'name': name,
        if (icon != null) 'icon': icon,
        'actions': actions.map((a) => a.toJson()).toList(),
      },
    );
    return Scene.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// PATCH /scenes/{id} — `actions` REPLACES the whole list, so send everything
  /// you want to keep.
  Future<Scene> updateScene(
    String id, {
    String? name,
    String? icon,
    List<SceneActionDraft>? actions,
  }) async {
    final response = await _dio.patch(
      ApiConstants.scene(id),
      data: {
        if (name != null) 'name': name,
        if (icon != null) 'icon': icon,
        if (actions != null) 'actions': actions.map((a) => a.toJson()).toList(),
      },
    );
    return Scene.fromJson(response.data['data'] as Map<String, dynamic>);
  }

  /// DELETE /scenes/{id} — 204. Soft delete on the backend.
  Future<void> deleteScene(String id) async {
    await _dio.delete(ApiConstants.scene(id));
  }

  Future<SceneActivationResult> activate(String sceneId) async {
    final response = await _dio.post(ApiConstants.sceneActivate(sceneId));
    final data = response.data['data'] as Map<String, dynamic>;
    return SceneActivationResult(
      executionId: data['executionId'] as String? ?? '',
      acceptedCount: data['acceptedCount'] as int? ?? 0,
      failed: (data['failed'] as List<dynamic>? ?? [])
          .map((f) {
            if (f is Map) {
              final device = f['deviceName'] as String? ?? 'device';
              final reason = f['reason'] as String? ?? 'unknown';
              return '$device ($reason)';
            }
            return f.toString();
          })
          .toList(),
    );
  }
}
