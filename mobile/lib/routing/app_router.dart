// =============================================================================
// SHE V3 — App router (go_router)
// =============================================================================
// V3-MOBILE-APP §2. go_router 14+.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/device_detail/device_detail_screen.dart';
import '../features/energy/energy_screen.dart';
import '../features/home/members_screen.dart';
import '../features/payments/payment_screen.dart';
import '../features/provisioning/provisioning_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/telemetry/telemetry_screen.dart';
import '../core/storage/secure_storage.dart';
import '../core/network/dio_client.dart';

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
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const DashboardScreen(),
      ),
      GoRoute(
        path: '/provisioning',
        builder: (context, state) => const ProvisioningScreen(),
      ),
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
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/payments/:plan',
        builder: (context, state) =>
            PaymentScreen(plan: state.pathParameters['plan']!),
      ),
    ],
  );
});

// ---- Locale provider (V3-I18N — Amharic first) ----
final StateProvider<Locale> localeProvider = StateProvider<Locale>((ref) {
  // Load from secure storage on init
  SecureStorage.getLocale().then((saved) {
    if (saved != null) {
      ref.read(localeProvider.notifier).state = Locale(saved);
    }
  });
  return const Locale('am');   // Default: Amharic
});
