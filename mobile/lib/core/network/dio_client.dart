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
Completer<bool>? _activeRefreshCompleter;

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
      // Mutex: if a refresh is already in progress, wait for it
      if (_isRefreshing && _activeRefreshCompleter != null) {
        final success = await _activeRefreshCompleter!.future;
        if (success) {
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
              // Retry failed — fall through
            }
          }
        }
      } else {
        // First 401 — perform the refresh
        _isRefreshing = true;
        _activeRefreshCompleter = Completer<bool>();
        final refreshed = await _refreshToken();
        _activeRefreshCompleter!.complete(refreshed);
        _isRefreshing = false;
        _activeRefreshCompleter = null;

        if (refreshed) {
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
              // Retry failed — fall through
            }
          }
        }
        // Refresh failed — clear tokens
        await SecureStorage.clearAll();
        ref.read(accessTokenProvider.notifier).state = null;
      }
    }
    handler.next(err);
  }

  Future<bool> _refreshToken() async {
    try {
      final refreshToken = await SecureStorage.getRefreshToken();
      if (refreshToken == null) return false;

      // Use the effective (possibly user-overridden) base URL, not the
      // build-time constant, or refresh would silently target a stale host.
      final dio = Dio(BaseOptions(baseUrl: ref.read(apiBaseUrlProvider)));
      final response = await dio.post(
        ApiConstants.authRefresh,
        data: {'refresh_token': refreshToken},
      );

      if (response.statusCode != null &&
          response.statusCode! >= 200 && response.statusCode! < 300) {
        final data = response.data['data'];
        if (data == null) return false;
        final newAccess = data['access_token'];
        final newRefresh = data['refresh_token'];
        if (newAccess is! String || newRefresh is! String) return false;
        ref.read(accessTokenProvider.notifier).state = newAccess;
        await SecureStorage.saveRefreshToken(newRefresh);
        return true;
      }
    } catch (e) {
      // Refresh failed
    }
    return false;
  }
}
