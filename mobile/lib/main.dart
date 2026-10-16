// =============================================================================
// SHE V3 — main.dart
// =============================================================================
// V3-MOBILE-APP §3. Entry point.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/network/dio_client.dart';
import 'core/offline/offline_automations.dart';
import 'core/storage/secure_storage.dart';
import 'core/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive (encrypted cache — V3-MOBILE-APP §7)
  await Hive.initFlutter();
  await Hive.openBox('she_cache');
  await Hive.openBox('pending_commands');
  // Automations created while offline, awaiting cloud sync (OfflineAutomationService).
  await Hive.openBox(pendingAutomationsBox);
  // User preferences (base URL overrides, etc.) — must be open before any
  // provider reads SettingsStore.
  await Hive.openBox(SettingsStore.boxName);

  // Initialize secure storage (tokens)
  await SecureStorage.init();

  // ---- Session restore (bugfix 2026-10-03, hardened 2026-10-04) ----
  // The access token is in-memory only by design (V3-SECURITY-MODEL §1.1) but
  // the refresh token IS persisted. Nothing used to read it at startup, so
  // `accessTokenProvider` began every launch as null and the router guard sent
  // the user straight to /login — every relaunch looked like a forced logout
  // even though the session was still valid on the server.
  //
  // Restoring here (before runApp, so the first router evaluation already sees
  // the token) makes a warm relaunch land on /dashboard instead.
  final container = ProviderContainer();
  await restoreSession(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SheApp(),
    ),
  );
}
