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
import 'features/robi/data/custom_voice_store.dart';
import 'core/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive (encrypted cache — V3-MOBILE-APP §7)
  await Hive.initFlutter();
  // Secure storage must be ready BEFORE the encrypted custom-commands box, whose
  // AES key lives there.
  await SecureStorage.init();
  await Hive.openBox('she_cache');
  await Hive.openBox('pending_commands');
  // Automations created while offline, awaiting cloud sync (OfflineAutomationService).
  await Hive.openBox(pendingAutomationsBox);
  // User-defined voice commands (custom phrases / macros). ENCRYPTED: these can
  // contain private phrases, so they must not sit in plaintext on disk.
  final hiveKey = await SecureStorage.getOrCreateHiveKey();
  await Hive.openBox(
    customCommandsBox,
    encryptionCipher: HiveAesCipher(hiveKey),
  );
  // User preferences (base URL overrides, etc.) — must be open before any
  // provider reads SettingsStore.
  await Hive.openBox(SettingsStore.boxName);

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
  // LOCAL-FIRST (2026-10-28): restoring against an unreachable backend used to
  // block launch for the whole connect timeout (8 s) — a black screen on a phone
  // that is simply not on the same Wi-Fi. Cap the wait at 3 s. The refresh keeps
  // running in the background; if it later succeeds, `accessTokenProvider` (the
  // router's refreshListenable) fires and the guard moves the user on its own.
  await restoreSession(container)
      .timeout(const Duration(seconds: 3), onTimeout: () => false);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SheApp(),
    ),
  );
}
