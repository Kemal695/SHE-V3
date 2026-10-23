// =============================================================================
// SHE V3 — Secure storage (tokens)
// =============================================================================
// V3-MOBILE-APP §2. flutter_secure_storage for JWT tokens.
// Access token: in-memory only (Riverpod provider).
// Refresh token: Keychain (iOS) / EncryptedSharedPreferences (Android).
// =============================================================================

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  // NOTE: there is deliberately NO access-token key here. The access token is
  // in-memory only (Riverpod `accessTokenProvider`) per V3-SECURITY-MODEL §1.1 —
  // only the refresh token is persisted. An `_accessTokenKey` constant used to
  // live here and was never used; it implied the access token might be written
  // to disk, which the security model forbids, so it was removed.
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

  // ---- Per-node proof-of-possession ----
  //
  // The PoP is generated during provisioning and needed afterwards for local
  // control, so it is kept per node id rather than in one slot.
  static Future<void> saveNodePop(String nodeId, String pop) =>
      _storage.write(key: 'node_pop_$nodeId', value: pop);

  static Future<String?> getNodePop(String nodeId) =>
      _storage.read(key: 'node_pop_$nodeId');

  static Future<void> deleteNodePop(String nodeId) =>
      _storage.delete(key: 'node_pop_$nodeId');

  // ---- Clear all (logout) ----
  static Future<void> clearAll() async {
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _tokenExpiryKey);
  }
}
