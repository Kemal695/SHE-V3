// =============================================================================
// SHE V3 — App Router (go_router 14+)
// =============================================================================
// Proper back-button handling:
//   - /login → back = exit app
//   - /dashboard → back = exit app (NOT go to login)
//   - /node/:id → back = dashboard
//   - /payments/:plan → back = previous screen
//
// SHELL (SHE-V3 UI/UX redesign, 2026-10-03)
// -----------------------------------------
// The five roots (dashboard / devices / automations / energy / more) live in a
// StatefulShellRoute so they get the prototype's persistent bottom nav, and so
// each tab keeps its own stack. Detail routes stay OUTSIDE the shell: they are
// pushed full-screen without the bottom bar, exactly as the prototype does
// (`noNav` screens) and as the old bottom bar effectively behaved.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/storage/settings_store.dart';

import '../core/storage/secure_storage.dart';
import '../core/network/dio_client.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/onboarding_screen.dart';
import '../features/auth/register_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/device_detail/device_detail_screen.dart';
import '../features/devices/devices_screen.dart';
import '../features/energy/energy_screen.dart';
import '../features/energy/home_energy_screen.dart';
import '../features/groups/group_detail_screen.dart';
import '../features/more/more_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/ota/ota_update_screen.dart';
import '../features/gate/gate_control_screen.dart';
import '../features/queued/queued_commands_screen.dart';
import '../features/payments/payment_screen.dart';
import '../features/automations/automations_screen.dart';
import '../features/provisioning/provisioning_screen.dart';
import '../features/scenes/scene_detail_screen.dart';
import '../features/scenes/scenes_screen.dart';
import '../features/settings/profile_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/voice/voice_screen.dart';
import '../features/telemetry/telemetry_screen.dart';
import '../features/home/members_screen.dart';
import 'app_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // M4 fix: redirect must react to auth-state changes (login/logout/token
  // expiry). GoRouter only re-evaluates redirect when refreshListenable fires,
  // so bridge the Riverpod token provider into a Listenable.
  final authListenable = ValueNotifier<String?>(ref.read(accessTokenProvider));
  ref.listen(accessTokenProvider, (_, value) => authListenable.value = value);
  ref.onDispose(authListenable.dispose);

  return GoRouter(
    // V3-UI-REDESIGN: cold start now opens the splash, which auto-advances to
    // /onboarding after ~2.1 s. A logged-in user is redirected straight to
    // /dashboard by the guard below, so the splash never blocks them.
    initialLocation: '/splash',
    refreshListenable: authListenable,
    redirect: (context, state) {
      final isLoggedIn = ref.read(accessTokenProvider) != null;
      final loc = state.matchedLocation;

      // Routes reachable without a session. `splash` and `onboarding` were added
      // by the UI redesign; leaving them out of this set would trap an
      // unauthenticated launch in a redirect loop back to /login.
      final isAuthRoute = loc == '/login' ||
          loc == '/register' ||
          loc == '/splash' ||
          loc == '/onboarding';

      if (!isLoggedIn && !isAuthRoute) return '/login';
      if (isLoggedIn && isAuthRoute) return '/dashboard';
      return null;
    },
    routes: [
      // ---- Pre-auth flow: Splash -> Onboarding -> Login ----
      // Full-screen, no bottom bar. Both are reachable while logged out (see the
      // redirect guard above).
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),

      // ---- Auth (no back to dashboard from these) ----
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),

      // =====================================================================
      // Shell — the five tab roots, each with its own Navigator.
      // =====================================================================
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          // ---- Branch 0: Home ----
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          // ---- Branch 1: Devices ----
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/devices',
                builder: (context, state) {
                  final homeId = state.uri.queryParameters['homeId'] ?? '';
                  return DevicesScreen(homeId: homeId);
                },
              ),
            ],
          ),
          // ---- Branch 2: Automations (scenes live alongside it) ----
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/automations',
                builder: (context, state) {
                  final homeId = state.uri.queryParameters['homeId'] ?? '';
                  return AutomationsScreen(homeId: homeId);
                },
              ),
            ],
          ),
          // ---- Branch 3: Energy (home-level dashboard) ----
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/energy',
                builder: (context, state) {
                  final homeId = state.uri.queryParameters['homeId'] ?? '';
                  return HomeEnergyScreen(homeId: homeId);
                },
              ),
            ],
          ),
          // ---- Branch 4: More (profile, settings, voice, premium) ----
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/more',
                builder: (context, state) => const MoreScreen(),
              ),
            ],
          ),
        ],
      ),

      // =====================================================================
      // Detail routes — full-screen, pushed OVER the shell (no bottom bar).
      // Paths and params are unchanged from before this redesign.
      // =====================================================================
      GoRoute(
        path: '/provisioning',
        builder: (context, state) => const ProvisioningScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/voice',
        builder: (context, state) => const VoiceScreen(),
      ),
      // Design sheet screen 15. Detail-style route (no bottom bar) so it reads
      // as a drill-down from the dashboard bell.
      GoRoute(
        path: '/notifications',
        builder: (context, state) => NotificationsScreen(
          homeId: state.uri.queryParameters['homeId'],
        ),
      ),
      // Design sheet screen 17. Detail-style route (no bottom bar), reached from
      // More. `admin` gates the ADMIN-only rollout controls — start / abort /
      // approve / decline are ADMIN+ per V3-API-SPECIFICATION §9, so a member
      // gets the read-only view instead of a control that would 403.
      GoRoute(
        path: '/ota',
        builder: (context, state) => OtaUpdateScreen(
          homeId: state.uri.queryParameters['homeId'],
          isAdmin: state.uri.queryParameters['admin'] == 'true',
        ),
      ),
      GoRoute(
        path: '/gate',
        builder: (context, state) => GateControlScreen(
          nodeId: state.uri.queryParameters['nodeId'],
          deviceId: state.uri.queryParameters['deviceId'],
          name: state.uri.queryParameters['name'],
          isOnline: state.uri.queryParameters['isOnline'] == 'true',
        ),
      ),
      GoRoute(
        path: '/queued',
        builder: (context, state) => const QueuedCommandsScreen(),
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
      // Design sheet screen 16. Declared AFTER /scenes — go_router matches on
      // the full path pattern, so the static route still wins for exactly
      // `/scenes` while `/scenes/<id>` lands here.
      GoRoute(
        path: '/scenes/:id',
        builder: (context, state) =>
            SceneDetailScreen(sceneId: state.pathParameters['id']!),
      ),

      // ---- Group detail ----
      // Opened from a group card on the home screen, mirroring how a Scenes card
      // opens its own page. homeId/nodeId/name ride as query params because the
      // group id alone is not enough to resolve the board it belongs to.
      GoRoute(
        path: '/groups/:id',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return GroupDetailScreen(
            groupId: state.pathParameters['id']!,
            homeId: q['homeId'] ?? '',
            nodeId: q['nodeId'] ?? '',
            groupName: q['name'] ?? 'Group',
          );
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

// ---- Theme mode provider (ADR-009 dark-first + optional light mode) ----
// Persisted in the Hive `settings` box. Dark stays the default, so an existing
// install is unaffected until the user opts into light mode.
final StateProvider<ThemeMode> themeModeProvider = StateProvider<ThemeMode>((ref) {
  return SettingsStore.themeMode == 'light' ? ThemeMode.light : ThemeMode.dark;
});
