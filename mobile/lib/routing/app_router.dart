// =============================================================================
// SHE V3 — App Router (go_router 14+)
// =============================================================================
// Proper back-button handling:
//   - /login → back = exit app
//   - /dashboard → back = exit app (NOT go to login)
//   - /node/:id → back = dashboard
//   - /payments/:plan → back = previous screen
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/storage/secure_storage.dart';
import '../core/network/dio_client.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/device_detail/device_detail_screen.dart';
import '../features/energy/energy_screen.dart';
import '../features/payments/payment_screen.dart';
import '../features/automations/automations_screen.dart';
import '../features/provisioning/provisioning_screen.dart';
import '../features/scenes/scenes_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/voice/voice_screen.dart';
import '../features/telemetry/telemetry_screen.dart';
import '../features/home/members_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // M4 fix: redirect must react to auth-state changes (login/logout/token
  // expiry). GoRouter only re-evaluates redirect when refreshListenable fires,
  // so bridge the Riverpod token provider into a Listenable.
  final authListenable = ValueNotifier<String?>(ref.read(accessTokenProvider));
  ref.listen(accessTokenProvider, (_, value) => authListenable.value = value);
  ref.onDispose(authListenable.dispose);

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: authListenable,
    redirect: (context, state) {
      final isLoggedIn = ref.read(accessTokenProvider) != null;
      final isAuthRoute = state.matchedLocation == '/login' ||
          state.matchedLocation == '/register';

      if (!isLoggedIn && !isAuthRoute) return '/login';
      if (isLoggedIn && isAuthRoute) return '/dashboard';
      return null;
    },
    routes: [
      // ---- Auth (no back to dashboard from these) ----
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),

      // ---- Main screens (back = exit app) ----
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const DashboardScreen(),
      ),
      GoRoute(
        path: '/provisioning',
        builder: (context, state) => const ProvisioningScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/voice',
        builder: (context, state) => const VoiceScreen(),
      ),

      // ---- Detail screens (back = previous screen) ----
      GoRoute(
        path: '/node/:id',
        builder: (context, state) =>
            DeviceDetailScreen(nodeId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/node/:id/energy',
        builder: (context, state) =>
            EnergyScreen(nodeId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/node/:id/telemetry',
        builder: (context, state) =>
            TelemetryScreen(nodeId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/home/:homeId/members',
        builder: (context, state) =>
            MembersScreen(homeId: state.pathParameters['homeId']!),
      ),
      GoRoute(
        path: '/payments/:plan',
        builder: (context, state) =>
            PaymentScreen(plan: state.pathParameters['plan']!),
      ),
      GoRoute(
        path: '/scenes',
        builder: (context, state) {
          // homeId is passed as a query param because the dashboard resolves it
          // at runtime from GET /api/v3/homes.
          final homeId = state.uri.queryParameters['homeId'] ?? '';
          return ScenesScreen(homeId: homeId);
        },
      ),
      GoRoute(
        path: '/automations',
        builder: (context, state) {
          final homeId = state.uri.queryParameters['homeId'] ?? '';
          return AutomationsScreen(homeId: homeId);
        },
      ),
    ],
  );
});

// ---- Locale provider (V3-I18N — Amharic first) ----
// NOTE: the explicit `StateProvider<Locale>` type annotation is REQUIRED. The
// initialiser calls ref.read(localeProvider.notifier) on itself, so without the
// annotation Dart cannot infer the type and fails with
// `top_level_cycle: the type of 'localeProvider' depends on itself`.
final StateProvider<Locale> localeProvider = StateProvider<Locale>((ref) {
  // Load from secure storage on init
  SecureStorage.getLocale().then((saved) {
    if (saved != null) {
      ref.read(localeProvider.notifier).state = Locale(saved);
    }
  });
  return const Locale('am');   // Default: Amharic
});
