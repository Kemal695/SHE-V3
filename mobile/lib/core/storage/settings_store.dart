// =============================================================================
// SHE V3 — User settings store (non-secret preferences)
// =============================================================================
// Backed by Hive so values survive restarts. Deliberately NOT in
// SecureStorage: these are convenience preferences, not credentials.
// =============================================================================

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

  /// True when the user has overridden either value.
  static bool get hasOverride =>
      _box.containsKey(_apiBaseUrlKey) || _box.containsKey(_wsBaseUrlKey);

  /// Drop the overrides and fall back to the build-time defaults.
  static Future<void> resetToDefaults() async {
    await _box.delete(_apiBaseUrlKey);
    await _box.delete(_wsBaseUrlKey);
  }
}
