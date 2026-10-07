// =============================================================================
// SHE V3 — Dio HTTP client + JWT interceptor
// =============================================================================
// V3-MOBILE-APP §2. Dio 5.x with auto-refresh on 401.
// =============================================================================

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/api_constants.dart';
import '../storage/secure_storage.dart';
import 'base_url_provider.dart';

// ---- Access token (in-memory only — V3-SECURITY-MODEL §1.1) ----
final accessTokenProvider = StateProvider<String?>((ref) => null);

// ---- Token refresh mutex (prevents concurrent 401 refresh race) ----
bool _isRefreshing = false;
Completer<RefreshOutcome>? _activeRefreshCompleter;

/// Refresh the access token using the stored refresh token.
///
/// Shared by the REST 401 interceptor and the WebSocket client: an idle app
/// makes no REST calls, so without a WS-initiated refresh the socket retried
/// the same expired JWT forever ("WS handshake rejected: Token expired" every
/// 60 s). Both callers go through this one mutex so a concurrent REST 401 and
/// WS reconnect cannot fire two refreshes and invalidate each other's
/// (single-use, rotating) refresh token.
///
/// Returns true if [accessTokenProvider] now holds a fresh token.
Future<bool> refreshAccessToken(Ref ref) async {
  return await refreshAccessTokenDetailed(ref) == RefreshOutcome.success;
}

/// Mutex-guarded refresh that reports WHY it failed.
///
/// Same single-flight guarantee as [refreshAccessToken] — the two share the
/// one [_isRefreshing] slot, so a REST 401 and a WS reconnect can never fire
/// two exchanges against the same single-use refresh token. A waiter inherits
/// the leader's full outcome, so it also learns whether the token was actually
/// revoked (rather than only "it didn't work").
Future<RefreshOutcome> refreshAccessTokenDetailed(Ref ref) async {
  // A refresh is already running — wait for its result instead of starting a
  // second one.
  if (_isRefreshing && _activeRefreshCompleter != null) {
    return _activeRefreshCompleter!.future;
  }

  _isRefreshing = true;
  final completer = Completer<RefreshOutcome>();
  _activeRefreshCompleter = completer;
  RefreshOutcome outcome = RefreshOutcome.transient;
  try {
    outcome = await _performRefreshDetailed(ref);
  } finally {
    _isRefreshing = false;
    _activeRefreshCompleter = null;
    completer.complete(outcome);
  }
  return outcome;
}

/// Outcome of a refresh attempt.
///
/// The distinction matters: [revoked] means the server actively rejected the
/// refresh token (401/403) and the user really must sign in again. [transient]
/// means we could not complete the exchange (offline, DNS failure, backend
/// restarting, 5xx) — the stored refresh token is probably still perfectly
/// valid, so it MUST NOT be deleted.
enum RefreshOutcome { success, revoked, transient }

/// Attempts a token refresh and reports WHY it failed.
Future<RefreshOutcome> _performRefreshDetailed(Ref ref) async {
  final refreshToken = await SecureStorage.getRefreshToken();
  if (refreshToken == null || refreshToken.isEmpty) {
    // Nothing to exchange. Not a revocation, but there is no session to keep
    // either, so the caller treats it as "not logged in".
    return RefreshOutcome.transient;
  }

  // Use the effective (possibly user-overridden) base URL, not the
  // build-time constant, or refresh would silently target a stale host.
  // A bare Dio instance: going through dioProvider would re-enter
  // JwtInterceptor and could recurse on a 401 from the refresh call itself.
  final dio = Dio(BaseOptions(baseUrl: ref.read(apiBaseUrlProvider)));

  Response<dynamic> response;
  try {
    response = await dio.post(
      ApiConstants.authRefresh,
      data: {'refresh_token': refreshToken},
    );
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      // The server looked at the refresh token and refused it.
      return RefreshOutcome.revoked;
    }
    // No response at all (socket/timeout/connection error) or a 5xx: the
    // server never accepted or rejected our token. Keep it.
    return RefreshOutcome.transient;
  } catch (_) {
    return RefreshOutcome.transient;
  }

  final status = response.statusCode;
  if (status == 401 || status == 403) return RefreshOutcome.revoked;
  if (status == null || status < 200 || status >= 300) {
    return RefreshOutcome.transient;
  }

  final data = response.data['data'];
  if (data == null) return RefreshOutcome.transient;
  final newAccess = data['access_token'];
  final newRefresh = data['refresh_token'];
  if (newAccess is! String || newRefresh is! String) {
    return RefreshOutcome.transient;
  }

  ref.read(accessTokenProvider.notifier).state = newAccess;
  await SecureStorage.saveRefreshToken(newRefresh);
  return RefreshOutcome.success;
}

// ---- Dio provider ----
final dioProvider = Provider<Dio>((ref) {
  // watch (not read): when the user changes the base URL in Settings, this
  // provider is recreated and every subsequent call uses the new endpoint.
  final dio = Dio(BaseOptions(
    baseUrl: ref.watch(apiBaseUrlProvider),
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
    headers: {
      ApiConstants.contentType: ApiConstants.applicationJson,
    },
  ));

  dio.interceptors.add(JwtInterceptor(ref));
  return dio;
});

/// Startup session restore.
///
/// Called ONCE from `main()` before `runApp`, so the very first router
/// evaluation already sees the restored token and the user lands on /dashboard
/// instead of /login.
///
/// WHY THIS IS A PLAIN FUNCTION AND NOT A PROVIDER (hardening, 2026-10-04):
/// the first version was a `FutureProvider` read once via `container.read(...)`.
/// Nothing watched it, so Riverpod auto-disposed it right after the read — and
/// because it performed a token refresh, any later re-execution burned the
/// SINGLE-USE rotating refresh token and logged the user out. A plain function
/// has no lifecycle to get wrong: it runs exactly when `main()` calls it.
///
/// Deliberately does NOT clear stored credentials on failure. A boot-time
/// refresh can fail for purely transient reasons (offline, backend restarting);
/// wiping the refresh token there would turn "no network yet" into "you are
/// logged out forever". Genuine revocation is still handled later by the 401
/// interceptor, which is the layer that actually knows the server said no.
///
/// Returns true when [accessTokenProvider] now holds a fresh token.
Future<bool> restoreSession(ProviderContainer container) async {
  try {
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;

    // `refreshAccessToken` needs a `Ref`; providers' bodies are the only place
    // one exists. Reading a throwaway provider's value gives us a live Ref
    // without introducing a cached token-refresh provider.
    final ok = await container.read(_sessionRestoreRunnerProvider.future);
    return ok;
  } catch (_) {
    // Stay logged out quietly — the guard shows /login and the user can sign in.
    return false;
  }
}

/// Internal one-shot used only to obtain a `Ref` for [restoreSession].
///
/// `keepAlive: true` is essential: an auto-disposed provider would re-run the
/// refresh (and rotate the single-use refresh token) if anything read it again.
final _sessionRestoreRunnerProvider = FutureProvider<bool>((ref) async {
  ref.keepAlive();
  final refreshToken = await SecureStorage.getRefreshToken();
  if (refreshToken == null || refreshToken.isEmpty) return false;
  return refreshAccessToken(ref);
});

// ---- JWT interceptor — adds Authorization header + auto-refresh on 401 ----
class JwtInterceptor extends Interceptor {
  final Ref ref;

  JwtInterceptor(this.ref);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = ref.read(accessTokenProvider);
    if (token != null) {
      options.headers[ApiConstants.authorization] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401) {
      // refreshAccessToken() owns the mutex: if a refresh (REST or WS-initiated)
      // is already in flight this awaits that same result instead of starting a
      // second one and burning the single-use refresh token.
      final outcome = await refreshAccessTokenDetailed(ref);

      if (outcome == RefreshOutcome.success) {
        final token = ref.read(accessTokenProvider);
        if (token != null) {
          final opts = err.requestOptions
            ..headers[ApiConstants.authorization] = 'Bearer $token';
          try {
            final dio = ref.read(dioProvider);
            final response = await dio.fetch(opts);
            handler.resolve(response);
            return;
          } catch (e) {
            // Retry failed — fall through to the error path.
          }
        }
      } else if (outcome == RefreshOutcome.revoked) {
        // The SERVER rejected the refresh token (401/403) — this really is the
        // end of the session, so clear it and let the guard show /login.
        //
        // NOTE: deliberately NOT done for RefreshOutcome.transient. The previous
        // code cleared credentials whenever refresh returned false, which
        // included plain network failures — so a momentary connectivity blip on
        // any request silently logged the user out and deleted their refresh
        // token. Only an explicit server rejection may do that.
        await SecureStorage.clearAll();
        ref.read(accessTokenProvider.notifier).state = null;
      }
    }
    handler.next(err);
  }
}
