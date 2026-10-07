// =============================================================================
// SHE V3 — Node service (Riverpod provider)
// =============================================================================
// V3-API-SPECIFICATION §6.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';

final nodeServiceProvider = Provider<NodeService>((ref) => NodeService(ref));

class NodeService {
  final Ref ref;
  NodeService(this.ref);

  Dio get _dio => ref.read(dioProvider);

  Future<List<Map<String, dynamic>>> listHomes() async {
    final response = await _dio.get('/api/v3/homes');
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  Future<List<Map<String, dynamic>>> listNodesByHome(String homeId) async {
    final response = await _dio.get(ApiConstants.homeNodes(homeId));
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  Future<Map<String, dynamic>> getNode(String nodeId) async {
    final response = await _dio.get(ApiConstants.node(nodeId));
    return response.data['data'];
  }

  Future<List<Map<String, dynamic>>> listDevices(String nodeId) async {
    final response = await _dio.get(ApiConstants.nodeDevices(nodeId));
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  Future<List<Map<String, dynamic>>> listParams(String nodeId, String deviceId) async {
    final response = await _dio.get(ApiConstants.nodeParams(nodeId, deviceId));
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  /// V3-API-SPECIFICATION §6 — write parameter command.
  /// Canonical body is FLAT: {"Power": true} or {"Brightness": 75}
  /// (the backend also still tolerates the legacy {"params": {...}} wrapper).
  Future<Map<String, dynamic>> writeParams(
      String nodeId, String deviceId, Map<String, dynamic> params) async {
    final response = await _dio.put(
      ApiConstants.nodeParams(nodeId, deviceId),
      data: params,
    );
    return response.data['data'];
  }

  /// ISO-8601 timestamp in UTC, safe to send as a backend `from`/`to` query param.
  ///
  /// `DateTime.toIso8601String()` omits the offset for a *local* DateTime, so the wire value
  /// looked like `2026-09-14T14:18:16.183777` with no zone. The backend binds these as `Instant`,
  /// which requires one, and rejected them with
  /// `DateTimeParseException: ... could not be parsed at index 26` — an unhandled 500 that left
  /// the Energy screen blank. Converting to UTC makes Dart append the `Z` designator.
  String _isoUtc(DateTime dt) => dt.toUtc().toIso8601String();

  Future<Map<String, dynamic>> getTelemetry(
      String nodeId, {DateTime? from, DateTime? to, String? param}) async {
    final queryParams = <String, dynamic>{
      'from': _isoUtc(from ?? DateTime.now().subtract(const Duration(days: 1))),
      'to': _isoUtc(to ?? DateTime.now()),
      'bucket': '5m',
    };
    if (param != null) queryParams['param'] = param;
    final response = await _dio.get(
      ApiConstants.nodeTelemetry(nodeId),
      queryParameters: queryParams,
    );
    return response.data['data'];
  }

  Future<List<Map<String, dynamic>>> getEnergyDaily(String nodeId,
      {int days = 7}) async {
    final response = await _dio.get(
      '${ApiConstants.nodeEnergy(nodeId)}/daily',
      queryParameters: {'days': days},
    );
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  Future<Map<String, dynamic>> getEnergy(
      String nodeId, {DateTime? from, DateTime? to}) async {
    final response = await _dio.get(ApiConstants.nodeEnergy(nodeId), queryParameters: {
      'from': _isoUtc(from ?? DateTime.now().subtract(const Duration(days: 1))),
      'to': _isoUtc(to ?? DateTime.now()),
    });
    return response.data['data'];
  }

  /// POST /api/v3/nodes/{id}/commands — out-of-band system command
  /// (V3-MQTT-STANDARDS §3.2). Fire-and-forget: a 200 means "queued", not "done".
  Future<Map<String, dynamic>> executeCommand(
    String nodeId,
    String cmd, {
    String? reason,
  }) async {
    final response = await _dio.post(
      ApiConstants.nodeCommands(nodeId),
      data: {
        'cmd': cmd,
        if (reason != null) 'reason': reason,
      },
    );
    return response.data['data'];
  }

  /// Drive a master/group intent (ADR-015) — "lights" | "sockets" | "all".
  ///
  /// Deliberately not a loop of per-channel [writeParams] calls. On the 24-relay
  /// board the lights are channels 0-7 and 16-23 with the sockets in between, so
  /// "all lights off" sent as "every channel off" would also kill the sockets;
  /// the device applies the group mask atomically instead.
  Future<Map<String, dynamic>> setGroup(
    String nodeId,
    String group,
    bool on, {
    String? reason,
  }) async {
    final response = await _dio.post(
      ApiConstants.nodeCommands(nodeId),
      data: {
        'cmd': 'group_set',
        'group': group,
        'on': on,
        if (reason != null) 'reason': reason,
      },
    );
    return response.data['data'];
  }

  // ─── Device rename + custom device groups (migration V36) ─────────────────

  /// PATCH /api/v3/nodes/{nodeId}/devices/{deviceId} — set display_name.
  /// Passing null/empty clears the custom name (the UI falls back to device_name).
  Future<Map<String, dynamic>> renameDevice(
      String nodeId, String deviceId, String? displayName) async {
    final response = await _dio.patch(
      ApiConstants.nodeDevice(nodeId, deviceId),
      data: {'display_name': displayName},
    );
    return response.data['data'];
  }

  /// GET /api/v3/homes/{homeId}/device-groups
  Future<List<Map<String, dynamic>>> listDeviceGroups(String homeId) async {
    final response = await _dio.get(ApiConstants.homeDeviceGroups(homeId));
    return List<Map<String, dynamic>>.from(response.data['data']);
  }

  /// POST /api/v3/homes/{homeId}/device-groups — {name, device_ids[], icon?, image?}
  ///
  /// `icon` / `image` are short asset keys (migration V37): the icon names a
  /// bundled glyph for the card, the image names a bundled photo for the detail
  /// hero. Both are optional — omitting them leaves the group to derive an icon
  /// from its members and show no hero photo.
  Future<Map<String, dynamic>> createDeviceGroup(
    String homeId,
    String name,
    List<String> deviceIds, {
    String? icon,
    String? image,
  }) async {
    final response = await _dio.post(
      ApiConstants.homeDeviceGroups(homeId),
      data: {
        'name': name,
        'device_ids': deviceIds,
        if (icon != null) 'icon': icon,
        if (image != null) 'image': image,
      },
    );
    return response.data['data'];
  }

  /// PATCH /api/v3/device-groups/{id} — {name?, device_ids?, icon?, image?}
  ///
  /// Only the keys you pass are sent, and the backend only overwrites what it
  /// receives — so a rename alone leaves a previously chosen icon/image intact.
  Future<Map<String, dynamic>> updateDeviceGroup(
    String groupId,
    String? name,
    List<String>? deviceIds, {
    String? icon,
    String? image,
  }) async {
    final response = await _dio.patch(
      ApiConstants.deviceGroup(groupId),
      data: {
        if (name != null) 'name': name,
        if (deviceIds != null) 'device_ids': deviceIds,
        if (icon != null) 'icon': icon,
        if (image != null) 'image': image,
      },
    );
    return response.data['data'];
  }

  /// DELETE /api/v3/device-groups/{id}
  Future<void> deleteDeviceGroup(String groupId) async {
    await _dio.delete(ApiConstants.deviceGroup(groupId));
  }

  /// POST /api/v3/device-groups/{id}/set — {on}
  Future<Map<String, dynamic>> setDeviceGroup(String groupId, bool on) async {
    final response = await _dio.post(
      ApiConstants.deviceGroupSet(groupId),
      data: {'on': on},
    );
    return response.data['data'];
  }

  /// POST /api/v3/auth/claim-token — 10-min TTL claim JWT (P1-3).
  Future<String> claimToken() async {
    final response = await _dio.post('/api/v3/auth/claim-token');
    return response.data['data']['claim_token'] as String;
  }

  Future<Map<String, dynamic>> claim({
    required String mac,
    required String claimToken,
    required String sku,
    String? homeId,
    Map<String, dynamic>? config,
  }) async {
    final response = await _dio.post(ApiConstants.nodeClaim, data: {
      'mac': mac,
      'claim_token': claimToken,
      'sku': sku,
      'home_id': homeId,
      'config': config ?? {},
    });
    return response.data['data'];
  }
}
