// =============================================================================
// SHE V3 — Design Tokens (V3-DESIGN-SYSTEM §1-2, ADR-009)
// =============================================================================
// Dark-mode first. Deep Navy + Bright Sky Blue. NO indigo/blue-purple.
// =============================================================================

import 'package:flutter/material.dart';

class V3Colors {
  // Dark mode (primary — ADR-009)
  static const background = Color(0xFF0B1D37);       // Deep Navy
  static const surface = Color(0xFF152946);           // Lighter Navy (cards)
  static const primary = Color(0xFF56B4FA);           // Bright Sky Blue
  static const secondary = Color(0xFF1D70B8);         // Medium Royal Blue
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA0AEC0);     // Muted Gray-Blue
  static const success = Color(0xFF00C853);
  static const error = Color(0xFFD50000);
  static const warning = Color(0xFFFFAB00);

  // ===========================================================================
  // Prototype palette (SHE-V3 UI/UX redesign, 2026-10-03)
  // ===========================================================================
  // The Next.js prototype at Desktop/SHE-V3-prototype-download locks a slightly
  // richer set than ADR-009. Additive only — every name above is unchanged, so
  // existing features keep compiling. These are the values the new screens use.
  //
  // Token map (prototype name -> here):
  //   #0B1D37 bg        -> background (already identical)
  //   #152946 surface   -> surface    (already identical)
  //   #1B3555 surface_2 -> surface2   (new — raised cards / active bento tiles)
  //   #56B4FA primary   -> primary    (already identical)
  //   #F5F9FF text_1    -> ink        (new — body copy; softer than pure white)
  //   #A8B8CC text_2    -> text2      (new; textSecondary above is #A0AEC0)
  //   #71839A text_muted-> dim        (new)
  //   #42D392 success   -> successAlt (new; success above is #00C853)
  //   #F5B84B warning   -> warningAlt (new; warning above is #FFAB00)
  //   #FF6678 error     -> errorAlt   (new; error above is #D50000)
  //   #8ED1FF sky       -> sky        (new — gradient tail on sliders/bars)
  //   #081527 night     -> night      (new — deeper than bg; on-primary text)
  static const surface2 = Color(0xFF1B3555);
  static const ink = Color(0xFFF5F9FF);
  static const text2 = Color(0xFFA8B8CC);
  static const dim = Color(0xFF71839A);
  static const successAlt = Color(0xFF42D392);
  static const warningAlt = Color(0xFFF5B84B);
  static const errorAlt = Color(0xFFFF6678);
  static const sky = Color(0xFF8ED1FF);
  static const night = Color(0xFF081527);

  // ---- Hairline / elevated surfaces ----
  // The prototype leans on white-at-low-alpha for borders and fills rather than
  // solid hex. These keep that consistent instead of each screen re-picking an
  // alpha (they had drifted between 0.06 and 0.12).
  static const border = Color(0x0FFFFFFF);        // white @ 6%  — default card edge
  static const borderStrong = Color(0x1FFFFFFF);  // white @ 12% — hover / active edge
  static const fill = Color(0x0DFFFFFF);          // white @ 5%  — inset rows, chips
  static const fillStrong = Color(0x17FFFFFF);    // white @ 9%  — pressed / selected

  // ---- Gradient stops used by the hero card, sliders and bars ----
  static const heroTop = Color(0xFF183457);
  static const heroMid = Color(0xFF122B4C);
  static const heroBottom = Color(0xFF0F2342);

  // Light mode (accessibility fallback)
  static const lightBackground = Color(0xFFF5F7FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightPrimary = Color(0xFF1D70B8);
  static const lightTextPrimary = Color(0xFF1A1A1A);
  static const lightTextSecondary = Color(0xFF6B7280);

  // Active glow shadow (V3-DESIGN-SYSTEM §1.8)
  static List<BoxShadow> activeGlow({bool isOn = true}) => isOn
      ? [BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 20, spreadRadius: 0)]
      : [];

  // Forbidden hues (system rule — enforced by lint + tenant branding validation)
  // #4F46E5 (Indigo 600), #6366F1 (Indigo 500), #7C3AED (Violet 600),
  // #8B5CF6 (Violet 500), #A855F7 (Purple 500), #9333EA (Purple 600)
  static const forbiddenHues = [
    Color(0xFF4F46E5), Color(0xFF6366F1), Color(0xFF7C3AED),
    Color(0xFF8B5CF6), Color(0xFFA855F7), Color(0xFF9333EA),
  ];

  static bool isForbiddenHue(Color color) {
    for (final forbidden in forbiddenHues) {
      if (color.toARGB32() == forbidden.toARGB32()) return true;
    }
    return false;
  }

  /// Prototype `KIND_MAP`: the tint a device kind glows with when active.
  ///
  /// Kept here (rather than in the widget) so the dashboard, the devices list
  /// and any future screen theme a given kind identically — the prototype
  /// defines this exactly once and every surface reads from it.
  static const Map<String, Color> deviceTint = {
    'light': warningAlt,       // #F5B84B
    'outlet': primary,         // #56B4FA
    'gate': sky,               // #8ED1FF
    'irrigation': successAlt,  // #42D392
    'camera': primary,
    'appliance': successAlt,
    'climate': sky,
    'meter': warningAlt,
    'sensor': text2,           // #A8B8CC
    'tv': primary,
    'generic': text2,
  };

  /// Fallback tint for an unknown kind — matches the prototype's `?? generic`.
  static Color tintForKind(String? kind) =>
      deviceTint[kind] ?? text2;

  /// A translucent wash of [color] at the prototype's `22` alpha (13%).
  ///
  /// `withValues` is the Flutter 3.27+ replacement for the deprecated
  /// `withOpacity`; the repo already standardised on it (see activeGlow).
  static Color wash(Color color, {double alpha = 0.13}) =>
      color.withValues(alpha: alpha);

  /// The glow the prototype uses on active device icons: `0 0 16px -4px tint55`.
  static List<BoxShadow> iconGlow(Color tint) => [
        BoxShadow(color: tint.withValues(alpha: 0.33), blurRadius: 16, spreadRadius: -4),
      ];

  /// Stronger card glow for an actively-lit tile (`0 0 24px -6px primary55`).
  static List<BoxShadow> cardGlow([Color? tint]) => [
        BoxShadow(
          color: (tint ?? primary).withValues(alpha: 0.35),
          blurRadius: 24,
          spreadRadius: -6,
        ),
      ];
}

class V3Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class V3Radius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;     // default for cards
  static const xl = 24.0;     // for modals
  static const full = 999.0;  // for avatars, circular buttons
}

class V3Duration {
  static const fast = Duration(milliseconds: 150);   // default transition
  static const medium = Duration(milliseconds: 300); // slider animation
  static const slow = Duration(milliseconds: 400);   // lock morph
  static const toggle = Duration(milliseconds: 60);  // snappy toggle (faster than Material)
  static const sceneFlash = Duration(milliseconds: 200);
  static const sceneStagger = Duration(milliseconds: 300);
}

class V3FontFamily {
  static const latin = 'Inter';
  static const amharic = 'NotoSansEthiopic';
  static const mono = 'JetBrainsMono';
}

// Responsive breakpoints (V3-DESIGN-SYSTEM §1.9 / ADR-009)
//
// Single source of truth for "how wide is the app right now". Screens read
// V3Breakpoints.sizeClass(context) / .gridColumns(context) instead of
// hand-rolling MediaQuery width checks (which had drifted between screens).
enum V3SizeClass {
  /// Phones — the existing single-column layout (unchanged).
  compact,

  /// Small tablets / large phones — 3-column grids (audit screen #24).
  medium,

  /// Foldables / desktop — 4-column grids (audit screen #25).
  expanded,
}

class V3Breakpoints {
  static const mobile = 600.0;    // < 600px = compact (phone)
  static const tablet = 900.0;    // 600-900px = medium (tablet)
  // ≥ 900px = expanded (foldable / desktop)

  static V3SizeClass sizeClass(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < mobile) return V3SizeClass.compact;
    if (w < tablet) return V3SizeClass.medium;
    return V3SizeClass.expanded;
  }

  /// True once the app is wide enough to swap the bottom nav for a side rail.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= mobile;

  /// Column count for the list/grid screens: 1 on phones (keeps the existing
  /// list layout), 3 on tablets, 4 on foldables/desktop.
  static int gridColumns(BuildContext context) {
    switch (sizeClass(context)) {
      case V3SizeClass.compact:
        return 1;
      case V3SizeClass.medium:
        return 3;
      case V3SizeClass.expanded:
        return 4;
    }
  }
}

// Typography scale (V3-DESIGN-SYSTEM §1.3)
class V3Typography {
  static const displaySize = 32.0;   // 700 weight, 1.2 line height
  static const headlineSize = 24.0;  // 600, 1.3
  static const titleSize = 20.0;     // 600, 1.3
  static const bodySize = 16.0;      // 400, 1.5 EN / 1.6 AM
  static const labelSize = 14.0;     // 500, 1.4
  static const captionSize = 12.0;   // 400, 1.4
  static const overlineSize = 10.0;  // 600, 1.2

  // Amharic line height is 1.6 (vs 1.4-1.5 for English)
  static double bodyLineHeight(String locale) =>
      locale == 'am' ? 1.6 : 1.5;

  // ---------------------------------------------------------------------------
  // Prototype micro-scale (SHE-V3 UI/UX redesign)
  // ---------------------------------------------------------------------------
  // The redesign uses a denser, phone-tuned scale than the §1.3 table above
  // (17px app-bar titles, 13.5px bento names, 11px meta rows). Named so screens
  // stop hand-rolling font sizes — that drift is what made the old screens
  // inconsistent. The §1.3 names above are untouched.
  static const appBarTitle = 17.0;   // SHEAppBar h1
  static const cardTitle = 13.5;     // bento / list item name
  static const body = 13.0;          // card body, empty-state copy
  static const meta = 11.0;          // room · state line
  static const chip = 12.5;          // filter chips, secondary buttons
  static const navLabel = 9.5;       // bottom-nav captions
  static const badge = 10.0;         // status pills
  static const micro = 9.0;          // axis labels
  static const metric = 24.0;        // energy numbers
  static const metricLg = 34.0;      // gauge centre
}
