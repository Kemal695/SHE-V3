// =============================================================================
// SHE V3 — Auth service (Riverpod provider)
// =============================================================================
// V3-MOBILE-APP §2. V3-API-SPECIFICATION §3.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';
import '../../core/storage/secure_storage.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService(ref));

class AuthService {
  final Ref ref;
  AuthService(this.ref);

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? fullName,
    String? phoneNumber,
    String? language,
  }) async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(ApiConstants.authRegister, data: {
      'email': email,
      'password': password,
      'full_name': fullName,
      'phone_number': phoneNumber,
      'language': language ?? 'am',
    });
    final data = response.data['data'];
    _saveTokens(data);
    return data;
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? mfaCode,
  }) async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(ApiConstants.authLogin, data: {
      'email': email,
      'password': password,
      'mfa_code': mfaCode,
    });
    final data = response.data['data'];
    _saveTokens(data);
    return data;
  }

  Future<void> logout() async {
    final dio = ref.read(dioProvider);
    final refreshToken = await SecureStorage.getRefreshToken();
    try {
      await dio.post(ApiConstants.authLogout, data: {
        'refresh_token': refreshToken,
      });
    } catch (_) {}
    await SecureStorage.clearAll();
    ref.read(accessTokenProvider.notifier).state = null;
  }

  Future<Map<String, dynamic>> me() async {
    final dio = ref.read(dioProvider);
    final response = await dio.get(ApiConstants.authMe);
    return response.data['data'];
  }

  void _saveTokens(Map<String, dynamic> data) {
    ref.read(accessTokenProvider.notifier).state = data['access_token'];
    SecureStorage.saveRefreshToken(data['refresh_token']);
    // Save expiry (expires_in seconds from now)
    SecureStorage.saveTokenExpiry(
      DateTime.now().add(Duration(seconds: data['expires_in'] ?? 900)),
    );
  }
}
