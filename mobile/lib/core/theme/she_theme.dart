// =============================================================================
// SHE V3 — Theme
// =============================================================================
// V3-DESIGN-SYSTEM, ADR-009 (dark-mode first, Bento grid).
// Deep Navy #0B1D37, Bright Sky Blue #56B4FA, NO indigo/blue-purple.
// =============================================================================

import 'package:flutter/material.dart';

class SheTheme {
  // ---- Brand colors (V3-DESIGN-SYSTEM §2) ----
  static const Color deepNavy = Color(0xFF0B1D37);          // background
  static const Color lighterNavy = Color(0xFF152946);       // surface cards
  static const Color brightSkyBlue = Color(0xFF56B4FA);     // accent / active glow
  static const Color textPrimary = Color(0xFFF5F7FA);
  static const Color textSecondary = Color(0xFF9BA8BC);
  static const Color textMuted = Color(0xFF6B7785);
  static const Color error = Color(0xFFFF5252);
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFC107);

  // ---- Spacing ----
  static const double radiusLg = 16.0;
  static const double radiusMd = 12.0;
  static const double radiusSm = 8.0;
  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 16.0;
  static const double spacingLg = 24.0;
  static const double spacingXl = 32.0;

  // ---- Active device glow (V3-DESIGN-SYSTEM §3) ----
  static List<BoxShadow> get activeGlow => [
        BoxShadow(
          color: brightSkyBlue.withOpacity(0.3),
          blurRadius: 20,
          spreadRadius: 0,
        ),
      ];

  static ThemeData get darkTheme => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: deepNavy,
        colorScheme: const ColorScheme.dark(
          primary: brightSkyBlue,
          secondary: brightSkyBlue,
          surface: lighterNavy,
          error: error,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: textPrimary,
          onError: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: deepNavy,
          foregroundColor: textPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: lighterNavy,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusLg),
          ),
          margin: EdgeInsets.zero,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: brightSkyBlue,
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMd),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: lighterNavy,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radiusMd),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          labelStyle: const TextStyle(color: textSecondary),
          hintStyle: const TextStyle(color: textMuted),
        ),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(color: textPrimary, fontSize: 28, fontWeight: FontWeight.bold),
          headlineMedium: TextStyle(color: textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
          titleLarge: TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
          titleMedium: TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
          bodyLarge: TextStyle(color: textPrimary, fontSize: 16),
          bodyMedium: TextStyle(color: textSecondary, fontSize: 14),
          bodySmall: TextStyle(color: textMuted, fontSize: 12),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF1F3A5F),
          thickness: 1,
          space: 1,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? brightSkyBlue : textMuted),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? brightSkyBlue.withOpacity(0.3) : textMuted.withOpacity(0.2)),
        ),
      );
}
