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

/// The signed-in user's profile: `GET /api/v3/auth/me`.
///
/// Shape (server: MeResponse): `{user: {...}, tenant: {...}}`.
///
/// Kept as a provider so the Profile screen can refresh/retry with
/// `ref.invalidate(meProvider)`.
final meProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.read(authServiceProvider).me();
});

/// A failed auth call, carrying the server's own error code and message.
///
/// Dio's raw `DioException` stringifies to "DioException [bad response]: ...",
/// which is not something to show a user. The backend answers failures with
/// `{"error": {"code", "message", "http_status"}}`, so unwrap that when present.
class AuthException implements Exception {
  AuthException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

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

  /// Confirm the signed-in user's password.
  ///
  /// The account is identified by the access token, so no email is needed. Unlike
  /// [login], a wrong password does NOT consume a login attempt — this endpoint
  /// is for local confirmations (e.g. resetting the voice-command PIN) and must
  /// never be able to lock the account out of the login screen.
  ///
  /// Throws (401) when the password is wrong.
  Future<void> verifyPassword(String password) async {
    final dio = ref.read(dioProvider);
    await dio.post(
      ApiConstants.authVerifyPassword,
      data: {'password': password},
    );
  }

  /// Ask for a password-reset token.
  ///
  /// Returns the token when the server has no mailer configured (this
  /// deployment), or null when it was emailed. Always succeeds for unknown
  /// addresses — the server will not reveal whether an account exists.
  Future<String?> requestPasswordReset(String email) async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(
      ApiConstants.authPasswordResetRequest,
      data: {'email': email},
    );
    final data = _responseData(response);
    return data['dev_token'] as String?;
  }

  /// Consume a reset token and set a new password.
  Future<void> confirmPasswordReset(String token, String newPassword) async {
    final dio = ref.read(dioProvider);
    await dio.post(ApiConstants.authPasswordResetConfirm, data: {
      'token': token,
      'new_password': newPassword,
    });
  }

  // ---------------------------------------------------------------------------
  // Two-factor authentication (TOTP)
  // ---------------------------------------------------------------------------

  /// Start enrolment. Returns the Base32 secret and the `otpauth://` URI for the
  /// QR code. Call [mfaConfirm] with a code from the authenticator app to finish.
  Future<Map<String, dynamic>> mfaEnroll() async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(ApiConstants.authMfaEnroll);
    return _responseData(response);
  }

  /// Verify a code from the authenticator app and switch MFA on.
  ///
  /// Returns the recovery codes — shown to the user ONCE and never again.
  Future<List<String>> mfaConfirm(String code) async {
    final dio = ref.read(dioProvider);
    final response = await dio.post(
      ApiConstants.authMfaConfirm,
      data: {'code': code},
    );
    final data = _responseData(response);
    return (data['recovery_codes'] as List?)?.cast<String>() ?? const [];
  }

  /// Switch MFA off. Requires the account password.
  Future<void> mfaDisable(String password) async {
    final dio = ref.read(dioProvider);
    await dio.post(ApiConstants.authMfaDisable, data: {'password': password});
  }

  /// Whether MFA is currently enabled for this account.
  Future<bool> mfaStatus() async {
    final dio = ref.read(dioProvider);
    final response = await dio.get(ApiConstants.authMfaStatus);
    return _responseData(response)['enabled'] == true;
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

  /// PATCH /auth/me — edit the signed-in user's own profile.
  ///
  /// Only the fields passed are sent, so a name-only edit cannot clear the phone
  /// number. Pass an empty string to clear a field.
  Future<Map<String, dynamic>> updateProfile({
    String? fullName,
    String? phoneNumber,
    String? preferredLanguage,
  }) async {
    final dio = ref.read(dioProvider);
    final response = await dio.patch(
      ApiConstants.authMe,
      data: {
        if (fullName != null) 'full_name': fullName,
        if (phoneNumber != null) 'phone_number': phoneNumber,
        if (preferredLanguage != null) 'preferred_language': preferredLanguage,
      },
    );
    return response.data['data'] as Map<String, dynamic>;
  }

  /// Replaces the signed-in user's password.
  ///
  /// `POST /api/v3/auth/change-password` → 204. The server verifies
  /// `currentPassword` itself (BCrypt) and answers 400 with
  /// `AUTH_CURRENT_PASSWORD_INVALID` when it does not match, or
  /// `VALIDATION_PASSWORD_UNCHANGED` when the new one equals the old one.
  ///
  /// Throws [AuthException] with the server's message so the caller can show
  /// something a user can act on.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final dio = ref.read(dioProvider);
    try {
      await dio.post(ApiConstants.authChangePassword, data: {
        'current_password': currentPassword,
        'new_password': newPassword,
      });
    } on DioException catch (e) {
      throw AuthException(
        _errorMessage(e) ?? 'Could not change the password. Please try again.',
        code: _errorCode(e),
      );
    }
  }

  /// The backend's `{"error": {"message": ...}}` envelope, if this response has
  /// one. Returns null for a network failure (no response at all) so the caller
  /// can substitute a generic message.
  String? _errorMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final msg = (data['error'] as Map)['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
    // A 404/405 means the server predates the endpoint — say so plainly rather
    // than blaming the user's password.
    final status = e.response?.statusCode;
    if (status == 404 || status == 405) {
      return 'This server does not support changing the password yet '
          '(update the backend to enable it).';
    }
    return null;
  }

  String? _errorCode(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final code = (data['error'] as Map)['code'];
      if (code is String) return code;
    }
    return null;
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
