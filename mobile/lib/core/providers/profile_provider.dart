// =============================================================================
// SHE V3 — Profile picture provider
// =============================================================================
// Local-only profile picture (the server has no avatar column). Seeded from
// SettingsStore; the Profile screen updates it after an upload so the dashboard
// header reflects the new picture live.
// =============================================================================

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/settings_store.dart';

final profileImageProvider =
    StateProvider<Uint8List?>((ref) => SettingsStore.profileImage);
