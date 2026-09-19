// =============================================================================
// SHE V3 — App root widget
// =============================================================================
// Premium dark-mode-first theme. Deep Navy + Bright Sky Blue. NO indigo.
// V3-DESIGN-SYSTEM §1-2. ADR-009.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme/v3_design_tokens.dart';
import 'l10n/app_localizations.dart';
import 'routing/app_router.dart';

class SheApp extends ConsumerWidget {
  const SheApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final locale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'Smart Home Ethiopia',
      debugShowCheckedModeBanner: false,

      // ---- Theme (V3-DESIGN-SYSTEM, ADR-009 — dark mode first) ----
      theme: _buildTheme(),
      darkTheme: _buildTheme(),
      themeMode: ThemeMode.dark,

      // ---- Localization (V3-I18N — Amharic first) ----
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // ---- Routing (go_router 14+) ----
      routerConfig: router,

      // ---- Premium scroll behavior — no overscroll glow on Android ----
      builder: (context, child) {
        return ScrollConfiguration(
          behavior: _NoGlowScrollBehavior(),
          child: child!,
        );
      },
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: V3Colors.background,
      colorScheme: const ColorScheme.dark(
        primary: V3Colors.primary,
        secondary: V3Colors.secondary,
        surface: V3Colors.surface,
        error: V3Colors.error,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: V3Colors.textPrimary,
        onError: Colors.white,
      ),

      // ---- AppBar ----
      appBarTheme: const AppBarTheme(
        backgroundColor: V3Colors.background,
        foregroundColor: V3Colors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: V3Colors.textPrimary,
          fontSize: V3Typography.headlineSize,
          fontWeight: FontWeight.w600,
        ),
      ),

      // ---- Cards ----
      cardTheme: CardThemeData(
        color: V3Colors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V3Radius.lg),
        ),
        margin: EdgeInsets.zero,
      ),

      // ---- Buttons ----
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: V3Colors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(V3Radius.md),
          ),
          textStyle: const TextStyle(
            fontSize: V3Typography.labelSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: V3Colors.primary,
          textStyle: const TextStyle(
            fontSize: V3Typography.bodySize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      // ---- Inputs (keyboard-safe) ----
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: V3Colors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V3Radius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V3Radius.md),
          borderSide: BorderSide(color: V3Colors.textSecondary.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V3Radius.md),
          borderSide: const BorderSide(color: V3Colors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(V3Radius.md),
          borderSide: const BorderSide(color: V3Colors.error),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: const TextStyle(color: V3Colors.textSecondary),
        hintStyle: TextStyle(color: V3Colors.textSecondary.withValues(alpha: 0.5)),
        floatingLabelStyle: const TextStyle(color: V3Colors.primary),
      ),

      // ---- Text ----
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.displaySize, fontWeight: FontWeight.w700, height: 1.2),
        headlineMedium: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.headlineSize, fontWeight: FontWeight.w600, height: 1.3),
        titleLarge: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600, height: 1.3),
        titleMedium: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.bodySize, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.bodySize, height: 1.5),
        bodyMedium: TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.labelSize),
        bodySmall: TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.captionSize),
        labelLarge: TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.labelSize, fontWeight: FontWeight.w500),
      ),

      // ---- Divider ----
      dividerTheme: DividerThemeData(
        color: V3Colors.textSecondary.withValues(alpha: 0.1),
        thickness: 1,
        space: 1,
      ),

      // ---- Switch (fallback — we use SHEToggle) ----
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? V3Colors.textPrimary : V3Colors.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? V3Colors.primary.withValues(alpha: 0.3) : V3Colors.textSecondary.withValues(alpha: 0.2)),
      ),

      // ---- Snackbar ----
      snackBarTheme: SnackBarThemeData(
        backgroundColor: V3Colors.surface,
        // Flutter 3.44 removed SnackBarThemeData.contentTextColor; style the
        // content text instead.
        contentTextStyle: const TextStyle(color: V3Colors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V3Radius.md)),
      ),

      // ---- Dialog ----
      dialogTheme: DialogThemeData(
        backgroundColor: V3Colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V3Radius.xl)),
        titleTextStyle: const TextStyle(color: V3Colors.textPrimary, fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600),
        contentTextStyle: const TextStyle(color: V3Colors.textSecondary, fontSize: V3Typography.bodySize),
      ),

      // ---- Bottom sheet ----
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: V3Colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
        ),
      ),
    );
  }
}

// No overscroll glow — premium feel
class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  // Flutter 3.44: the third parameter is ScrollableDetails, not ScrollMetrics.
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;  // No glow — premium apps don't show overscroll
  }
}
