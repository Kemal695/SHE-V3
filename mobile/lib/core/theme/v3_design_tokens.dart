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

// Bento grid breakpoints (V3-DESIGN-SYSTEM §1.9)
class V3Breakpoints {
  static const mobile = 600.0;    // ≤ 600px = 2 columns
  static const tablet = 900.0;     // 600-900px = 3 columns
  // ≥ 900px = 4 columns (desktop/foldable)
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
}
