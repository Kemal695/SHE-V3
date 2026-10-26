// =============================================================================
// SHE V3 — Secure storage (tokens)
// =============================================================================
// V3-MOBILE-APP §2. flutter_secure_storage for JWT tokens.
// Access token: in-memory only (Riverpod provider).
// Refresh token: Keychain (iOS) / EncryptedSharedPreferences (Android).
// =============================================================================

import 'dart:convert';
import 'dart:math';

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

  // ---- Voice recognition language ----
  //
  // Independent of the UI locale: a user may read Amharic but speak English.
  // null = auto (follow the UI locale), 'en' = force English, 'am' = force
  // Amharic. The recognizer reads this in AndroidSpeechProvider.probe.
  static const _voiceLocaleKey = 'voice_locale';

  static Future<void> saveVoiceLocale(String? locale) => locale == null
      ? _storage.delete(key: _voiceLocaleKey)
      : _storage.write(key: _voiceLocaleKey, value: locale);

  static Future<String?> getVoiceLocale() =>
      _storage.read(key: _voiceLocaleKey);

  // ---- Custom voice command PIN ----
  //
  // Optional gate for the "My commands" page: when set, the page (and therefore
  // the list of custom phrases) is hidden behind this PIN. Stored in encrypted
  // storage, never in Hive.
  static const _commandPinKey = 'custom_cmd_pin';

  static Future<void> saveCommandPin(String pin) =>
      _storage.write(key: _commandPinKey, value: pin);

  static Future<String?> getCommandPin() =>
      _storage.read(key: _commandPinKey);

  static Future<void> clearCommandPin() =>
      _storage.delete(key: _commandPinKey);

  // ---- Custom command Hive key ----
  //
  // The custom-commands box is encrypted, because its contents are the user's
  // private phrases. The 32-byte AES key lives in encrypted storage; if it is
  // ever lost the box simply reads empty (see CustomCommandsNotifier._read) —
  // it never crashes, it just forgets the custom commands.
  static const _hiveKeyKey = 'custom_cmd_hive_key';

  static Future<List<int>> getOrCreateHiveKey() async {
    final existing = await _storage.read(key: _hiveKeyKey);
    if (existing != null && existing.isNotEmpty) {
      try {
        final decoded = base64Decode(existing);
        if (decoded.length == 32) return decoded;
      } catch (_) {
        // Corrupt value: regenerate below.
      }
    }
    final rnd = Random.secure();
    final key = List<int>.generate(32, (_) => rnd.nextInt(256));
    await _storage.write(key: _hiveKeyKey, value: base64Encode(key));
    return key;
  }

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
