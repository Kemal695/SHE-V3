// =============================================================================
// SHE V3 — WebSocket client
// =============================================================================
// V3-API-SPECIFICATION §14. P1-4: auth via Sec-WebSocket-Protocol: bearer.<jwt>.
// NOT ?token= query param (leaks in logs).
// =============================================================================

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants/api_constants.dart';
import 'dio_client.dart';
import '../../features/device_detail/device_detail_screen.dart';

final wsClientProvider = Provider<WsClient>((ref) {
  final client = WsClient(ref);
  ref.onDispose(() => client.dispose());
  return client;
});

class WsClient {
  final Ref ref;
  WebSocketChannel? _channel;
  bool _isConnected = false;

  // Reconnect with exponential backoff (V3-MOBILE-APP §8)
  int _reconnectDelay = 1;
  static const int _maxReconnectDelay = 60;

  WsClient(this.ref);

  bool get isConnected => _isConnected;

  Future<void> connect() async {
    if (_isConnected) return;

    final accessToken = ref.read(accessTokenProvider);
    if (accessToken == null) return;

    final uri = Uri.parse('${ApiConstants.wsBaseUrl}${ApiConstants.wsPath}');

    // P1-4: Sec-WebSocket-Protocol: bearer.<jwt>
    _channel = WebSocketChannel.connect(
      uri,
      protocols: ['bearer.$accessToken'],
    );

    _isConnected = true;
    _reconnectDelay = 1;

    _channel!.stream.listen(
      (message) => _onMessage(message),
      onError: (error) => _onError(error),
      onDone: () => _onDone(),
    );
  }

  void _onMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final event = json['event'] as String?;
      final data = json['data'] as Map<String, dynamic>?;
      if (event == null || data == null) return;

      if (event == 'node.state' || event == 'energy.update') {
        final nodeId = data['nodeId'] as String?;
        if (nodeId != null) {
          ref.invalidate(nodeDevicesProvider(nodeId));
        }
      }
      print('WS event: $event data: $data');
    } catch (e) {
      print('WS message parse error: $e');
    }
  }

  void _onError(dynamic error) {
    print('WS error: $error');
    _isConnected = false;
    _scheduleReconnect();
  }

  void _onDone() {
    _isConnected = false;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    Future.delayed(Duration(seconds: _reconnectDelay), () {
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, _maxReconnectDelay);
      connect();
    });
  }

  void send(Map<String, dynamic> message) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void subscribeToHome(String homeId) {
    send({'action': 'subscribe', 'scope': 'home', 'home_id': homeId});
  }

  void subscribeToNode(String nodeId) {
    send({'action': 'subscribe', 'scope': 'node', 'node_id': nodeId});
  }

  void unsubscribeNode(String nodeId) {
    send({'action': 'unsubscribe', 'scope': 'node', 'node_id': nodeId});
  }

  void dispose() {
    _channel?.sink.close();
    _isConnected = false;
  }
}
