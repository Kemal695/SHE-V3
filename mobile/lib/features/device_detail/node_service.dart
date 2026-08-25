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

  /// V3-MQTT-STANDARDS §3.4 — write parameter command.
  /// Body: {"Power": true} or {"Brightness": 75}
  Future<Map<String, dynamic>> writeParams(
      String nodeId, String deviceId, Map<String, dynamic> params) async {
    final response = await _dio.put(
      ApiConstants.nodeParams(nodeId, deviceId),
      data: {'params': params},
    );
    return response.data['data'];
  }

  Future<Map<String, dynamic>> getTelemetry(
      String nodeId, {DateTime? from, DateTime? to, String? param}) async {
    final queryParams = <String, dynamic>{
      'from': (from ?? DateTime.now().subtract(const Duration(days: 1))).toIso8601String(),
      'to': (to ?? DateTime.now()).toIso8601String(),
      'bucket': '5m',
    };
    if (param != null) queryParams['param'] = param;
    final response = await _dio.get(
      ApiConstants.nodeTelemetry(nodeId),
      queryParameters: queryParams,
    );
    return response.data['data'];
  }

  Future<Map<String, dynamic>> getEnergy(
      String nodeId, {DateTime? from, DateTime? to}) async {
    final response = await _dio.get(ApiConstants.nodeEnergy(nodeId), queryParameters: {
      'from': (from ?? DateTime.now().subtract(const Duration(days: 1))).toIso8601String(),
      'to': (to ?? DateTime.now()).toIso8601String(),
    });
    return response.data['data'];
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
