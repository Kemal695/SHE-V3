// =============================================================================
// SHE V3 — app.dart
// =============================================================================
// Root widget. V3-MOBILE-APP §3.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme/she_theme.dart';
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

      // ---- Theme (V3-DESIGN-SYSTEM, ADR-009) ----
      theme: SheTheme.darkTheme,
      darkTheme: SheTheme.darkTheme,

      // ---- Localization (V3-I18N — Amharic first) ----
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // ---- Routing ----
      routerConfig: router,
    );
  }
}
