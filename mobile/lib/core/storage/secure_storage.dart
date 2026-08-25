// =============================================================================
// SHE V3 — Secure storage (tokens)
// =============================================================================
// V3-MOBILE-APP §2. flutter_secure_storage for JWT tokens.
// Access token: in-memory only (Riverpod provider).
// Refresh token: Keychain (iOS) / EncryptedSharedPreferences (Android).
// =============================================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _tokenExpiryKey = 'token_expiry';
  static const _localeKey = 'locale';

  static late FlutterSecureStorage _storage;

  static Future<void> init() async {
    _storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    );
  }

  // ---- Refresh token (persisted securely) ----
  static Future<void> saveRefreshToken(String token) =>
      _storage.write(key: _refreshTokenKey, value: token);

  static Future<String?> getRefreshToken() =>
      _storage.read(key: _refreshTokenKey);

  static Future<void> deleteRefreshToken() =>
      _storage.delete(key: _refreshTokenKey);

  // ---- Token expiry (for proactive refresh) ----
  static Future<void> saveTokenExpiry(DateTime expiry) =>
      _storage.write(key: _tokenExpiryKey, value: expiry.toIso8601String());

  static Future<DateTime?> getTokenExpiry() async {
    final s = await _storage.read(key: _tokenExpiryKey);
    return s != null ? DateTime.parse(s) : null;
  }

  // ---- Locale preference ----
  static Future<void> saveLocale(String locale) =>
      _storage.write(key: _localeKey, value: locale);

  static Future<String?> getLocale() => _storage.read(key: _localeKey);

  // ---- Clear all (logout) ----
  static Future<void> clearAll() async {
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _tokenExpiryKey);
  }
}
