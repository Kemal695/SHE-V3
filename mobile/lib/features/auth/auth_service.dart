// =============================================================================
// SHE V3 — Auth service (Riverpod provider)
// =============================================================================
// V3-MOBILE-APP §2. V3-API-SPECIFICATION §3.
// =============================================================================

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

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
    final data = _responseData(response);
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
    final data = _responseData(response);
    _saveTokens(data);
    return data;
  }

  /// Sign in with Google. The native SDK returns an ID token which the backend
  /// verifies against Google's JWKS before issuing our JWT pair. Creates the
  /// account (and a default home) on first sign-in.
  Future<Map<String, dynamic>> loginWithGoogle() async {
    final signIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
      serverClientId: ApiConstants.googleServerClientId.isEmpty
          ? null
          : ApiConstants.googleServerClientId,
    );
    final account = await signIn.signIn();
    if (account == null) {
      throw Exception('Google sign-in cancelled');
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw Exception('Google did not return an ID token');
    }
    return _oauthLogin(ApiConstants.authOauthGoogle, idToken);
  }

  /// Sign in with Apple. `sign_in_with_apple` returns an identity token which the
  /// backend verifies against Apple's JWKS.
  Future<Map<String, dynamic>> loginWithApple() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final idToken = credential.identityToken;
    if (idToken == null || idToken.isEmpty) {
      throw Exception('Apple did not return an identity token');
    }
    return _oauthLogin(ApiConstants.authOauthApple, idToken);
  }

  Future<Map<String, dynamic>> _oauthLogin(String path, String idToken) async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(path, data: {'id_token': idToken});
    final data = _responseData(response);
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

  /// Unwraps the canonical {data: {...}} envelope with safe casts (M9 fix).
  Map<String, dynamic> _responseData(Response response) {
    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw Exception('Invalid server response (expected JSON object)');
    }
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid server response (missing data envelope)');
    }
    return data;
  }

  void _saveTokens(Map<String, dynamic> data) {
    // M9 fix: validate shapes instead of blind dynamic casts — a malformed
    // auth response used to crash with an opaque TypeError.
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || access.isEmpty) {
      throw Exception('Invalid auth response (missing access_token)');
    }
    if (refresh is! String || refresh.isEmpty) {
      throw Exception('Invalid auth response (missing refresh_token)');
    }
    ref.read(accessTokenProvider.notifier).state = access;
    SecureStorage.saveRefreshToken(refresh);
    // Save expiry (expires_in seconds from now)
    final expiresIn = data['expires_in'];
    SecureStorage.saveTokenExpiry(
      DateTime.now().add(Duration(seconds: expiresIn is int ? expiresIn : 900)),
    );
  }
}
