// =============================================================================
// SHE V3 — Theme-aware colour palette (ADR-009 dark-first + optional light mode)
// =============================================================================
// Single source of truth for the app's colours.
//
// `V3Colors.*` (the legacy static API referenced across ~40 screens) delegates
// to [SheColors.current], so switching the palette re-themes the whole app
// WITHOUT rewriting every call site. Material widgets read the same values via
// the [ThemeExtension] registration in `app.dart`.
//
// ⚠️ Because the palette is now runtime-switchable, `V3Colors.*` is no longer a
// compile-time constant — call sites that used it inside a `const` expression
// must drop the `const`.
// =============================================================================

import 'package:flutter/material.dart';

@immutable
class SheColors extends ThemeExtension<SheColors> {
  const SheColors({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.primary,
    required this.secondary,
    required this.textPrimary,
    required this.textSecondary,
    required this.success,
    required this.error,
    required this.warning,
    required this.ink,
    required this.text2,
    required this.dim,
    required this.successAlt,
    required this.warningAlt,
    required this.errorAlt,
    required this.sky,
    required this.night,
    required this.border,
    required this.borderStrong,
    required this.fill,
    required this.fillStrong,
    required this.heroTop,
    required this.heroMid,
    required this.heroBottom,
  });

  final Color background;
  final Color surface;
  final Color surface2;
  final Color primary;
  final Color secondary;
  final Color textPrimary;
  final Color textSecondary;
  final Color success;
  final Color error;
  final Color warning;
  final Color ink;
  final Color text2;
  final Color dim;
  final Color successAlt;
  final Color warningAlt;
  final Color errorAlt;
  final Color sky;
  final Color night;
  final Color border;
  final Color borderStrong;
  final Color fill;
  final Color fillStrong;
  final Color heroTop;
  final Color heroMid;
  final Color heroBottom;

  /// The palette currently in use.
  ///
  /// Kept in sync with the app's ThemeData by `SheApp` so the legacy
  /// `V3Colors.*` getters resolve to the right values.
  static SheColors current = dark;

  /// Dark mode (primary — ADR-009).
  static const SheColors dark = SheColors(
    background: Color(0xFF0B1D37), // Deep Navy
    surface: Color(0xFF152946), // cards
    surface2: Color(0xFF1B3555), // raised cards / active tiles
    primary: Color(0xFF56B4FA), // Bright Sky Blue
    secondary: Color(0xFF1D70B8),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA0AEC0),
    success: Color(0xFF00C853),
    error: Color(0xFFD50000),
    warning: Color(0xFFFFAB00),
    ink: Color(0xFFF5F9FF),
    text2: Color(0xFFA8B8CC),
    dim: Color(0xFF71839A),
    successAlt: Color(0xFF42D392),
    warningAlt: Color(0xFFF5B84B),
    errorAlt: Color(0xFFFF6678),
    sky: Color(0xFF8ED1FF),
    night: Color(0xFF081527),
    border: Color(0x0FFFFFFF), // white @ 6%
    borderStrong: Color(0x1FFFFFFF), // white @ 12%
    fill: Color(0x0DFFFFFF), // white @ 5%
    fillStrong: Color(0x17FFFFFF), // white @ 9%
    heroTop: Color(0xFF183457),
    heroMid: Color(0xFF122B4C),
    heroBottom: Color(0xFF0F2342),
  );

  /// Light mode.
  ///
  /// Keeps the SHE brand (sky-blue accent) but darkens it enough to stay legible
  /// on white; the dark palette's white-at-low-alpha hairlines become
  /// black-at-low-alpha, and the hero gradient becomes a soft white→pale-blue.
  static const SheColors light = SheColors(
    background: Color(0xFFF4F7FB),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE9EFF7),
    primary: Color(0xFF1D70B8),
    secondary: Color(0xFF56B4FA),
    textPrimary: Color(0xFF14202E),
    textSecondary: Color(0xFF5B6B7F),
    success: Color(0xFF0E9F52),
    error: Color(0xFFC62828),
    warning: Color(0xFFB26A00),
    ink: Color(0xFF1A2230),
    text2: Color(0xFF4A5568),
    dim: Color(0xFF7A8899),
    successAlt: Color(0xFF12A150),
    warningAlt: Color(0xFFC77700),
    errorAlt: Color(0xFFD64545),
    sky: Color(0xFF2E90E5),
    night: Color(0xFFFFFFFF), // on-primary text
    border: Color(0x14000000), // black @ 8%
    borderStrong: Color(0x24000000), // black @ 14%
    fill: Color(0x0A000000), // black @ 4%
    fillStrong: Color(0x12000000), // black @ 7%
    heroTop: Color(0xFFFFFFFF),
    heroMid: Color(0xFFF1F6FC),
    heroBottom: Color(0xFFE7EFF9),
  );

  @override
  SheColors copyWith({
    Color? background,
    Color? surface,
    Color? surface2,
    Color? primary,
    Color? secondary,
    Color? textPrimary,
    Color? textSecondary,
    Color? success,
    Color? error,
    Color? warning,
    Color? ink,
    Color? text2,
    Color? dim,
    Color? successAlt,
    Color? warningAlt,
    Color? errorAlt,
    Color? sky,
    Color? night,
    Color? border,
    Color? borderStrong,
    Color? fill,
    Color? fillStrong,
    Color? heroTop,
    Color? heroMid,
    Color? heroBottom,
  }) {
    return SheColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      primary: primary ?? this.primary,
      secondary: secondary ?? this.secondary,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      success: success ?? this.success,
      error: error ?? this.error,
      warning: warning ?? this.warning,
      ink: ink ?? this.ink,
      text2: text2 ?? this.text2,
      dim: dim ?? this.dim,
      successAlt: successAlt ?? this.successAlt,
      warningAlt: warningAlt ?? this.warningAlt,
      errorAlt: errorAlt ?? this.errorAlt,
      sky: sky ?? this.sky,
      night: night ?? this.night,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      fill: fill ?? this.fill,
      fillStrong: fillStrong ?? this.fillStrong,
      heroTop: heroTop ?? this.heroTop,
      heroMid: heroMid ?? this.heroMid,
      heroBottom: heroBottom ?? this.heroBottom,
    );
  }

  /// Theme transitions snap between the two palettes (no colour tween) — the
  /// app has no animated theme change, so this keeps the switch crisp.
  @override
  SheColors lerp(ThemeExtension<SheColors>? other, double t) {
    if (other is! SheColors) return this;
    return t < 0.5 ? this : other;
  }
}

/// `context.sheColors` — theme-aware access for new code.
extension SheColorsContext on BuildContext {
  SheColors get sheColors =>
      Theme.of(this).extension<SheColors>() ?? SheColors.current;
}
