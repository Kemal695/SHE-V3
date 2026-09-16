// =============================================================================
// SHE V3 — main.dart
// =============================================================================
// V3-MOBILE-APP §3. Entry point.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'core/storage/secure_storage.dart';
import 'core/storage/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive (encrypted cache — V3-MOBILE-APP §7)
  await Hive.initFlutter();
  await Hive.openBox('she_cache');
  await Hive.openBox('pending_commands');
  // User preferences (base URL overrides, etc.) — must be open before any
  // provider reads SettingsStore.
  await Hive.openBox(SettingsStore.boxName);

  // Initialize secure storage (tokens)
  await SecureStorage.init();

  runApp(const ProviderScope(child: SheApp()));
}
