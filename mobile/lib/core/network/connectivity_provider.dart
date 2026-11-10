// =============================================================================
// SHE V3 — Connectivity status (design sheet screen 22 — Offline state)
// =============================================================================
// V3-MOBILE-APP §7: "Online-first, offline-tolerant — not offline-first."
// "Connectivity banner: 'You're offline. Showing cached data.' (amber banner at
// top, dismissible)."
//
// SIGNAL CHOICE
// -------------
// This app has no `connectivity_plus` dependency and adding one would mean a
// plugin registration plus a full rebuild. Instead connectivity is derived from
// the live WebSocket link — the app's lifeline for real-time state
// (`wsConnectedProvider`). While the socket is up we are, by definition, able to
// reach SHE; when it drops we allow a short grace period (transient blips and
// normal reconnects are routine) and only then declare the app offline.
//
// AUTH-GATED: before login there is deliberately no socket, so the splash/login
// screens must NOT read as "offline". The controller ignores WS state until an
// access token exists, and resets to online when the session ends.
// =============================================================================

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dio_client.dart';
import 'ws_client.dart';

/// Online = the live link to SHE is up. Offline = it has been down past the
/// grace period, so the app is showing cached data (V3-MOBILE-APP §7).
enum ConnectivityStatus { online, offline }

final connectivityStatusProvider =
    NotifierProvider<ConnectivityController, ConnectivityStatus>(
  ConnectivityController.new,
);

class ConnectivityController extends Notifier<ConnectivityStatus> {
  Timer? _graceTimer;

  /// How long the socket must stay down before the banner appears. Long enough
  /// to ride out a normal reconnect / brief radio blip; short enough that a real
  /// outage is surfaced promptly.
  static const Duration _grace = Duration(seconds: 8);

  @override
  ConnectivityStatus build() {
    ref.onDispose(() => _graceTimer?.cancel());

    // React to live-link changes (auth-gated inside [_onSocket]).
    ref.listen<bool>(wsConnectedProvider, (_, up) => _onSocket(up));

    // Session changes: logging out resets to online (a logged-out app has no
    // socket by design); logging in re-evaluates against the current socket.
    ref.listen<String?>(accessTokenProvider, (_, token) {
      if (token == null) {
        _graceTimer?.cancel();
        state = ConnectivityStatus.online;
      } else {
        _onSocket(ref.read(wsConnectedProvider));
      }
    });

    // Evaluate the CURRENT socket state, not only future changes. If the app is
    // launched while ALREADY offline (backend down, no network), the socket was
    // never up, so there is no false→true transition for the listener above to
    // fire on and the banner would never appear — which is exactly what a cold
    // start with the backend down looked like ("Cannot reach SHE cloud" with no
    // banner). At a normal start the socket connects within the grace period and
    // cancels this timer, so there is still no false positive.
    if (ref.read(accessTokenProvider) != null &&
        !ref.read(wsConnectedProvider)) {
      _graceTimer = Timer(_grace, () {
        state = ConnectivityStatus.offline;
      });
    }

    // Optimistic start; the timer above (or a socket event) corrects it.
    return ConnectivityStatus.online;
  }

  void _onSocket(bool up) {
    // Pre-auth: no socket is expected, so WS state is meaningless here.
    if (ref.read(accessTokenProvider) == null) return;

    _graceTimer?.cancel();
    if (up) {
      state = ConnectivityStatus.online;
      return;
    }
    _graceTimer = Timer(_grace, () async {
      // The socket is a NOTIFICATION channel, not a liveness probe. It closes on
      // token expiry (code 1000) and on ordinary network blips (code 1006) while
      // HTTP keeps working. Declaring "offline" on socket state alone is what
      // swapped the Devices page onto cached data — and when the cache was thin,
      // the page looked like it had emptied itself.
      //
      // So confirm with a real request before believing it. Only a failed
      // request means offline.
      if (await _httpReachable()) {
        state = ConnectivityStatus.online;
        // HTTP works, so the socket is the only thing broken: nudge it instead
        // of showing the user an outage banner.
        ref.read(wsClientProvider).reconnectNow();
        return;
      }
      state = ConnectivityStatus.offline;
    });
  }

  /// Does the backend answer at all? A cheap real request, not a socket state.
  ///
  /// Any response below 500 counts as reachable — a 401 still proves the server
  /// is there, and treating it as "offline" would be a lie.
  Future<bool> _httpReachable() async {
    try {
      await ref.read(dioProvider).get<dynamic>(
            '/actuator/health',
            options: Options(
              receiveTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
              validateStatus: (code) => code != null && code < 500,
            ),
          );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The banner's "Retry": nudge the socket to reconnect immediately instead of
  /// waiting out its exponential backoff. The subscription to the active home is
  /// preserved by [WsClient.reconnectNow].
  void retry() {
    ref.read(wsClientProvider).reconnectNow();
  }
}
