// =============================================================================
// SHE V3 — WebSocket client
// =============================================================================
// V3-API-SPECIFICATION §14. P1-4: auth via Sec-WebSocket-Protocol: bearer.<jwt>.
// NOT ?token= query param (leaks in logs).
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants/api_constants.dart';
import 'base_url_provider.dart';
import 'dio_client.dart';
import '../../features/device_detail/device_detail_screen.dart';
import '../../features/payments/subscription_provider.dart';

final wsClientProvider = Provider<WsClient>((ref) {
  final client = WsClient(ref);
  ref.onDispose(() => client.dispose());
  return client;
});

/// Reactive mirror of [WsClient.isConnected].
///
/// [WsClient.isConnected] is a plain getter, so a widget cannot `watch` it and
/// would never rebuild when the socket drops or recovers. The dashboard needs
/// that to show a live/offline indicator, so the client mirrors every state
/// change into this provider via [_WsClientSetConnected].
final wsConnectedProvider = StateProvider<bool>((ref) => false);

class WsClient {
  final Ref ref;
  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _disposed = false;
  int _generation = 0;

  /// Single place that mutates [_isConnected] so the reactive mirror
  /// ([wsConnectedProvider]) can never drift out of sync with it.
  set _connected(bool value) {
    _isConnected = value;
    ref.read(wsConnectedProvider.notifier).state = value;
  }

  // Reconnect with exponential backoff (V3-MOBILE-APP §8)
  int _reconnectDelay = 1;
  static const int _maxReconnectDelay = 60;

  // Client-side keepalive. The server implements `ping` -> `pong`
  // (WsEventBus.handleTextMessage) but the app never sent it, so an idle
  // foreground socket got torn down by the phone radio / NAT / container idle
  // handling within seconds (CloseStatus 1006, reason=null). A 25 s ping keeps
  // the connection alive and surfaces a dead socket quickly via onDone.
  Timer? _pingTimer;
  static const Duration _pingInterval = Duration(seconds: 25);

  // Home the client is currently subscribed to (so switching homes unsubscribes
  // the previous one instead of accumulating subscriptions).
  String? _subscribedHomeId;

  // Guard against a refresh storm when the handshake keeps failing for a reason
  // that is NOT an expired token (server down, TLS, wrong host): we allow at
  // most one WS-initiated refresh per _authRefreshCooldown.
  DateTime? _lastAuthRefresh;
  static const Duration _authRefreshCooldown = Duration(seconds: 60);

  // Refresh this long BEFORE the JWT's `exp` so a token that dies mid-handshake
  // (or a small device/server clock skew) does not cost us a rejected attempt.
  static const Duration _expirySkew = Duration(seconds: 60);

  WsClient(this.ref) {
    // P1-4 follow-up: when the access token is rotated — by a REST 401 in
    // JwtInterceptor or by our own pre-handshake refresh below — the running WS
    // still carries the OLD JWT. Reconnect so the socket presents the fresh one.
    //
    // NOTE: deliberately NOT gated on _isConnected. The common case is a token
    // that rotates while the socket is already DOWN (backgrounded app); gating
    // on _isConnected made this listener a no-op exactly when it was needed and
    // left the reconnect to the 60 s backoff loop.
    ref.listen<String?>(accessTokenProvider, (previous, next) {
      if (next == null || next == previous || _disposed) return;
      if (_isConnected) {
        _reconnectWithNewToken();
      } else {
        // Socket already down — reconnect immediately with the new token
        // instead of waiting out the remaining backoff.
        _reconnectDelay = 1;
        connect(homeId: _subscribedHomeId);
      }
    });
  }

  bool get isConnected => _isConnected;

  Future<void> connect({String? homeId}) async {
    // M12 fix: never connect after dispose; only one live generation at a
    // time so stale reconnect timers can't resurrect zombie sockets.
    if (_isConnected || _disposed) return;
    final generation = ++_generation;

    var accessToken = ref.read(accessTokenProvider);
    if (accessToken == null) return;

    // The WS handshake is rejected outright on an expired JWT, and a
    // backgrounded app issues no REST calls — so nothing would ever refresh the
    // token and the reconnect loop presented the same dead JWT every 60 s
    // ("WS handshake rejected: JWT verification failed: Token expired"), never
    // self-healing. Refresh BEFORE handshaking if the token is already expired.
    if (_isTokenExpired(accessToken)) {
      final refreshed = await _refreshTokenForWs();
      if (_disposed || generation != _generation) return;
      if (!refreshed) {
        // Refresh token missing/revoked — the session is over. Stop retrying;
        // a new login sets accessTokenProvider and our listener reconnects.
        _connected = false;
        return;
      }
      // NOTE: read into a fresh nullable local. `accessToken` has been promoted
      // to non-nullable String by the null check above, so assigning
      // ref.read(...) directly makes Dart infer ref.read<String>(...) and the
      // StateProvider<String?> no longer matches.
      final rotated = ref.read(accessTokenProvider);
      if (rotated == null) return;
      accessToken = rotated;
    }

    // Effective (possibly user-overridden) base URL — see base_url_provider.dart.
    final uri = Uri.parse('${ref.read(wsBaseUrlProvider)}${ApiConstants.wsPath}');

    // P1-4: Sec-WebSocket-Protocol: bearer.<jwt> — the JWT rides in the subprotocol
    // so it never appears in a URL or a cookie.
    //
    // We must ALSO offer the bare `bearer` token. The server selects `bearer` as its
    // response subprotocol (deliberately, so the JWT is not echoed back in the 101
    // response headers — the H13 fix in WsAuthInterceptor). RFC 6455 §4.1 requires the
    // client to fail the connection if the server's chosen subprotocol was not among
    // the ones offered, and dart:io enforces exactly that:
    //
    //     _close(WebSocketStatus.protocolError, ...)   // code 1002
    //
    // Offering only `bearer.<jwt>` therefore made every handshake die instantly — the
    // server logged "WS connected" and then immediately "WS closed: code=1002", and
    // the app silently received no live updates at all.
    _channel = WebSocketChannel.connect(
      uri,
      protocols: ['bearer', 'bearer.$accessToken'],
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
      // Handshake failed. We already pre-checked `exp`, so if the server still
      // rejected the upgrade the cause may be a device/server clock skew or a
      // server-side revocation that our local check cannot see. Try exactly one
      // cooldown-limited refresh so we cannot loop on a dead token again; a
      // successful refresh fires the accessTokenProvider listener, which
      // reconnects and supersedes this generation.
      await _maybeRefreshAfterHandshakeFailure();
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

    _connected = true;
    _reconnectDelay = 1;
    _startPingTimer();

    // Auto-subscribe to the active home so the socket actually receives
    // node.state / energy.update / node.presence events (previously the app
    // connected but never subscribed, so live updates never arrived).
    if (homeId != null) subscribeToHome(homeId);

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
      final deviceId = data['deviceId'] as String?;
      switch (event) {
        case 'node.state':
          // THE live-state path. The device reported a param (params/local), so
          // refetch exactly that device's params. Invalidating nodeDevicesProvider
          // alone was NOT enough: DeviceResponse carries no params, so the
          // per-device switches stayed stale — that was the "the toggle is not
          // changing the state" bug.
          if (nodeId != null) {
            ref.invalidate(nodeDevicesProvider(nodeId));
            if (deviceId != null) {
              ref.invalidate(nodeDeviceParamsProvider('$nodeId|$deviceId'));
            }
          }
          break;
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
        case 'subscription_activated':
          // Backend activated/extended the subscription after a Chapa webhook.
          // Drop the cached subscription so subscribers refetch the new plan.
          ref.invalidate(currentSubscriptionProvider);
          break;
      }
    } catch (e) {
      debugPrint('WS message parse error: $e');
    }
  }

  void _onError(dynamic error, int generation) {
    debugPrint('WS error: $error');
    _connected = false;
    _scheduleReconnect(generation);
  }

  void _onDone(int generation) {
    _connected = false;
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    Future.delayed(Duration(seconds: _reconnectDelay), () {
      // Drop stale timers (dispose or newer generation superseded us).
      if (_disposed || generation != _generation) return;
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, _maxReconnectDelay);
      // Re-subscribe to the home we were watching: a bare connect() produced a
      // live socket with no subscription, so the UI got no live events after
      // any drop/reconnect.
      connect(homeId: _subscribedHomeId);
    });
  }

  void send(Map<String, dynamic> message) {
    if (_channel != null && _isConnected && !_disposed) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void subscribeToHome(String homeId) {
    if (_subscribedHomeId != null && _subscribedHomeId != homeId) {
      send({'action': 'unsubscribe', 'scope': 'home', 'home_id': _subscribedHomeId});
    }
    _subscribedHomeId = homeId;
    send({'action': 'subscribe', 'scope': 'home', 'home_id': homeId});
  }

  void subscribeToNode(String nodeId) {
    send({'action': 'subscribe', 'scope': 'node', 'node_id': nodeId});
  }

  void unsubscribeNode(String nodeId) {
    send({'action': 'unsubscribe', 'scope': 'node', 'node_id': nodeId});
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_isConnected && !_disposed) send({'action': 'ping'});
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  /// Token was rotated by the auth layer — close and reconnect so the next
  /// handshake carries the fresh JWT (connect() re-reads accessTokenProvider).
  void _reconnectWithNewToken() {
    _stopPingTimer();
    try {
      _channel?.sink.close(1000, 'token rotated');
    } catch (_) {}
    _channel = null;
    _connected = false;
    _reconnectDelay = 1;
    // Preserve the active subscription across the reconnect, otherwise the new
    // socket is connected but silent (no home subscription => no live events).
    connect(homeId: _subscribedHomeId);
  }

  /// True if the JWT's `exp` claim is already past (minus [_expirySkew]).
  ///
  /// An unparseable token is reported as NOT expired: the server is the
  /// authority on validity, and this check exists only to avoid a handshake we
  /// know is doomed — it must never block an otherwise usable token.
  bool _isTokenExpired(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return false;
      // base64url -> base64 + re-pad (JWT strips '=' padding).
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (payload.length % 4) {
        case 2:
          payload += '==';
          break;
        case 3:
          payload += '=';
          break;
      }
      final claims =
          jsonDecode(utf8.decode(base64.decode(payload))) as Map<String, dynamic>;
      final exp = claims['exp'];
      if (exp is! int) return false;
      final expiry =
          DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      return DateTime.now().toUtc().isAfter(expiry.subtract(_expirySkew));
    } catch (_) {
      return false;
    }
  }

  /// Refresh the access token for the WS path, recording the attempt so
  /// [_maybeRefreshAfterHandshakeFailure] cannot spin.
  Future<bool> _refreshTokenForWs() async {
    _lastAuthRefresh = DateTime.now();
    return refreshAccessToken(ref);
  }

  /// One refresh attempt per [_authRefreshCooldown] after a failed handshake.
  /// Without the cooldown a non-auth failure (backend down, wrong host) would
  /// trigger a refresh on every single reconnect attempt.
  Future<void> _maybeRefreshAfterHandshakeFailure() async {
    final last = _lastAuthRefresh;
    if (last != null && DateTime.now().difference(last) < _authRefreshCooldown) {
      return;
    }
    await _refreshTokenForWs();
  }

  void dispose() {
    _disposed = true;
    _stopPingTimer();
    _generation++;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connected = false;
  }
}
