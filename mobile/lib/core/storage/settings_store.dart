// =============================================================================
// SHE V3 — User settings store (non-secret preferences)
// =============================================================================
// Backed by Hive so values survive restarts. Deliberately NOT in
// SecureStorage: these are convenience preferences, not credentials.
// =============================================================================

import 'dart:typed_data';

import 'package:hive/hive.dart';

import '../constants/api_constants.dart';

class SettingsStore {
  static const String boxName = 'settings';

  static const String _apiBaseUrlKey = 'api_base_url';
  static const String _wsBaseUrlKey = 'ws_base_url';

  static Box get _box => Hive.box(boxName);

  // ---- API base URL ----
  /// Falls back to the compile-time --dart-define value when unset.
  static String get apiBaseUrl =>
      (_box.get(_apiBaseUrlKey) as String?) ?? ApiConstants.apiBaseUrl;

  static Future<void> setApiBaseUrl(String value) =>
      _box.put(_apiBaseUrlKey, value);

  // ---- WebSocket base URL ----
  static String get wsBaseUrl =>
      (_box.get(_wsBaseUrlKey) as String?) ?? ApiConstants.wsBaseUrl;

  static Future<void> setWsBaseUrl(String value) => _box.put(_wsBaseUrlKey, value);

  // ---- Theme mode (ADR-009 dark-first + optional light mode) ----
  static const String _themeModeKey = 'theme_mode';

  /// 'dark' (default) or 'light'. Stored as a primitive string so the Hive box
  /// stays primitive-only.
  static String get themeMode => (_box.get(_themeModeKey) as String?) ?? 'dark';

  static Future<void> setThemeMode(String value) =>
      _box.put(_themeModeKey, value);

  // ---- Avatar accent (local-only preference, Profile screen) ----
  static const String _avatarColorIndexKey = 'avatar_color_index';

  /// Index into the Profile screen's avatar swatch palette. 0 by default.
  static int get avatarColorIndex =>
      (_box.get(_avatarColorIndexKey) as int?) ?? 0;

  static Future<void> setAvatarColorIndex(int value) =>
      _box.put(_avatarColorIndexKey, value);

  // ---- Profile picture (local-only; no avatar column on the server) ----
  static const String _profileImageKey = 'profile_image';

  /// Uploaded profile picture as raw bytes (Hive stores Uint8List natively).
  /// Null until the user sets one.
  static Uint8List? get profileImage =>
      _box.get(_profileImageKey) as Uint8List?;

  static Future<void> setProfileImage(Uint8List? value) =>
      _box.put(_profileImageKey, value);

  /// True when the user has overridden either value.
  static bool get hasOverride =>
      _box.containsKey(_apiBaseUrlKey) || _box.containsKey(_wsBaseUrlKey);

  // ---- Local control PoP (V3-FIRMWARE §7) ----
  static const String _localPopKey = 'local_control_pop';

  /// The device's 9-digit local-control PoP. Empty when unset — local control is
  /// then skipped entirely and offline commands fall back to the queue.
  static String get localPop => (_box.get(_localPopKey) as String?) ?? '';

  static Future<void> setLocalPop(String value) =>
      _box.put(_localPopKey, value);

  static const String _localHostKey = 'local_control_host';

  /// Optional manual board address (IP or hostname) for local control. Needed
  /// when mDNS discovery is unavailable — e.g. a firmware build with the mDNS
  /// component disabled — so the user can point the app straight at the board.
  static String get localHost => (_box.get(_localHostKey) as String?) ?? '';

  static Future<void> setLocalHost(String value) =>
      _box.put(_localHostKey, value);

  /// Drop every override and fall back to the build-time defaults.
  static Future<void> resetToDefaults() async {
    await _box.delete(_apiBaseUrlKey);
    await _box.delete(_wsBaseUrlKey);
    // Local control is an override too. Leaving the PoP/board IP behind after a
    // "reset" kept local control silently enabled with stale credentials.
    await _box.delete(_localPopKey);
    await _box.delete(_localHostKey);
    await _box.delete(_themeModeKey);
  }
}
