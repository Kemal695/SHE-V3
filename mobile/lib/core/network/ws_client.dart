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
  bool _disposed = false;
  int _generation = 0;

  // Reconnect with exponential backoff (V3-MOBILE-APP §8)
  int _reconnectDelay = 1;
  static const int _maxReconnectDelay = 60;

  WsClient(this.ref);

  bool get isConnected => _isConnected;

  Future<void> connect() async {
    // M12 fix: never connect after dispose; only one live generation at a
    // time so stale reconnect timers can't resurrect zombie sockets.
    if (_isConnected || _disposed) return;
    final generation = ++_generation;

    final accessToken = ref.read(accessTokenProvider);
    if (accessToken == null) return;

    final uri = Uri.parse('${ApiConstants.wsBaseUrl}${ApiConstants.wsPath}');

    // P1-4: Sec-WebSocket-Protocol: bearer.<jwt>
    _channel = WebSocketChannel.connect(
      uri,
      protocols: ['bearer.$accessToken'],
    );

    // M12 fix (part 2): do NOT mark connected until the handshake actually
    // completes. `WebSocketChannel.connect` returns synchronously, so setting
    // _isConnected here would report a live socket before the server has
    // accepted the upgrade — and `send()` would silently write into a channel
    // that is about to fail. Await `ready` first, and bail out if we were
    // disposed or superseded while waiting.
    try {
      await _channel!.ready;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      _onError(e, generation);
      return;
    }

    if (_disposed || generation != _generation) {
      // Superseded (dispose / newer generation) while awaiting the handshake.
      try {
        _channel?.sink.close();
      } catch (_) {}
      return;
    }

    _isConnected = true;
    _reconnectDelay = 1;

    _channel!.stream.listen(
      (message) => _onMessage(message),
      onError: (error) => _onError(error, generation),
      onDone: () => _onDone(generation),
    );
  }

  void _onMessage(String message) {
    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final event = json['event'] as String?;
      final data = json['data'];
      if (event == null || data is! Map<String, dynamic>) return;

      // M3 fix: dispatch WS events into Riverpod so the UI updates live.
      final nodeId = data['nodeId'] as String?;
      switch (event) {
        case 'node.state':
        case 'energy.update':
          if (nodeId != null) ref.invalidate(nodeDevicesProvider(nodeId));
          break;
        case 'node.presence':
        case 'node.telemetry':
          if (nodeId != null) {
            ref.invalidate(nodeDetailProvider(nodeId));
            ref.invalidate(nodeDevicesProvider(nodeId));
          }
          break;
        case 'ota.progress':
          break;
      }
    } catch (e) {
      print('WS message parse error: $e');
    }
  }

  void _onError(dynamic error, int generation) {
    print('WS error: $error');
    _isConnected = false;
    _scheduleReconnect(generation);
  }

  void _onDone(int generation) {
    _isConnected = false;
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    Future.delayed(Duration(seconds: _reconnectDelay), () {
      // Drop stale timers (dispose or newer generation superseded us).
      if (_disposed || generation != _generation) return;
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, _maxReconnectDelay);
      connect();
    });
  }

  void send(Map<String, dynamic> message) {
    if (_channel != null && _isConnected && !_disposed) {
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
    _disposed = true;
    _generation++;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _isConnected = false;
  }
}
