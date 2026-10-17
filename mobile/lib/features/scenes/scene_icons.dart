// =============================================================================
// SHE V3 — Scene icon catalogue
// =============================================================================
// One source of truth for the icon keys a scene may store and the glyph each
// renders as. The scene editor's picker, the Scenes page cards and the
// dashboard's scene row all read this map.
//
// Before this existed the editor had no picker at all (Save echoed the existing
// icon, so an icon could never change) and the dashboard used its own
// substring matcher that only knew sunrise/door/movie/moon — every other key
// silently rendered as the fallback sparkle.
// =============================================================================

import 'package:flutter/material.dart';

/// Icon key -> glyph. Keys are what the API stores in `scenes.icon`.
const Map<String, IconData> kSceneIconChoices = {
  'scene': Icons.auto_awesome,
  'sunrise': Icons.wb_twilight,
  'sunset': Icons.nightlight_outlined,
  'moon': Icons.dark_mode_outlined,
  'sun': Icons.wb_sunny_outlined,
  'door-open': Icons.meeting_room_outlined,
  'tv': Icons.tv_outlined,
  'droplets': Icons.water_drop_outlined,
  'shield': Icons.shield_outlined,
  'clock': Icons.schedule,
  'coffee': Icons.coffee_outlined,
};

/// Glyph for a stored icon key. Unknown/null falls back to the sparkle so a
/// scene authored elsewhere still renders.
IconData sceneIconFor(String? key) =>
    kSceneIconChoices[key] ?? Icons.auto_awesome;
