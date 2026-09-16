// =============================================================================
// SHE V3 — Runtime-configurable base URLs
// =============================================================================
// The API and WebSocket base URLs are baked in at build time via --dart-define.
// That meant every network change (new router, new DHCP lease) required a full
// APK rebuild — ~10 minutes each time. These providers hold the *effective*
// value, seeded from persistent settings and falling back to the build-time
// default, so the URLs can be changed from the Settings screen instead.
//
// Both clients `watch` these providers, so changing a URL recreates them and
// the next request uses the new endpoint.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/settings_store.dart';

/// Effective REST base URL (persisted override, else build-time default).
final apiBaseUrlProvider =
    StateProvider<String>((ref) => SettingsStore.apiBaseUrl);

/// Effective WebSocket base URL (persisted override, else build-time default).
final wsBaseUrlProvider =
    StateProvider<String>((ref) => SettingsStore.wsBaseUrl);
