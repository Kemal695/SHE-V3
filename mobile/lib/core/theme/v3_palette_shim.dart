// =============================================================================
// SHE V3 — Theme bridge (V3Palette shim)
// =============================================================================
// The desktop repo addresses colours through `context.v3` (a V3Palette
// ThemeExtension). The working app uses static getters on [V3Colors] instead.
// This shim exposes the same surface — `context.v3.<color>` — so desktop
// screens can be ported verbatim without rewriting every colour reference.
//
// Only the colours the ported screens actually read are bridged here.
// =============================================================================

import 'package:flutter/material.dart';

import 'v3_design_tokens.dart';

/// Minimal mirror of the desktop [V3Palette] colour surface, backed by the
/// working app's [V3Colors] getters.
class V3PaletteShim {
  const V3PaletteShim();

  Color get background => V3Colors.background;
  Color get surface => V3Colors.surface;
  Color get primary => V3Colors.primary;
  Color get secondary => V3Colors.secondary;
  Color get textPrimary => V3Colors.textPrimary;
  Color get textSecondary => V3Colors.textSecondary;
  Color get success => V3Colors.success;
  Color get error => V3Colors.error;
  Color get warning => V3Colors.warning;
  Color get onPrimary => Colors.white;
}

/// `context.v3` — the palette for the active theme (bridged).
extension V3PaletteShimContext on BuildContext {
  V3PaletteShim get v3 => const V3PaletteShim();
}
