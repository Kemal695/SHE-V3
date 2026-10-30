// =============================================================================
// SHE V3 — More screen (redesigned, 2026-10-27)
// =============================================================================
// Rebuilt to mirror the desktop/web Settings page: a clean, sectioned list of
// destinations instead of the old cramped control hub.
//
// Per the redesign brief:
//   • KEEP & surface the pages the user likes (local admin / OTA, Settings,
//     Profile, Parent devices, Alerts, Telemetry) — each routes to an EXISTING
//     destination; this screen adds no new screens, only surfaces them.
//   • REMOVE Add device / Automations / Scenes / Energy (they live in the
//     bottom-nav tabs / dashboard, so listing them here was redundant).
//   • MERGE the voice cluster (Robi, Voice language, Voice control, Voice
//     commands) into a single "Voice & Robi" section.
//
// Telemetry is per-node in this app, so the tile deep-links the active home's
// first board; if none resolve yet it falls back to the device list.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/dio_client.dart';
import '../../core/offline/command_queue.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';
import '../../core/network/active_home.dart';
import '../../features/device_detail/node_service.dart';
import '../../features/settings/robi_wake_tile.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/storage/settings_store.dart';
import '../../core/providers/profile_provider.dart';
import '../../routing/app_router.dart';
import '../auth/auth_service.dart';

/// Email of the signed-in user, when the backend exposes it.
/// Best-effort: returns null rather than throwing, so the header still renders.
final _profileEmailProvider = FutureProvider<String?>((ref) async {
  try {
    final res = await ref.read(dioProvider).get('/api/v3/users/me');
    final data = (res.data['data'] as Map?) ?? const {};
    return (data['email'] ?? data['phone'])?.toString();
  } catch (_) {
    return null;
  }
});

/// Voice recognition language: null = auto (follow the UI locale), 'en', 'am'.
/// Separate from the UI locale so someone can read Amharic but speak English.
final _voiceLocaleProvider =
    FutureProvider<String?>((ref) => SecureStorage.getVoiceLocale());

class MoreScreen extends ConsumerStatefulWidget {
  const MoreScreen({super.key});

  @override
  ConsumerState<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends ConsumerState<MoreScreen> {
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';
  String _homeId = _defaultHomeId;
  String? _nodeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveContext());
  }

  /// Resolve the ACTIVE home (not `homes.first`, which is arbitrary for a
  /// tenant with many "My Home" husks) and, from it, the first board so the
  /// Telemetry tile can deep-link straight to its history.
  Future<void> _resolveContext() async {
    final homeId = await resolveActiveHomeId(ref);
    if (!mounted) return;
    setState(() => _homeId = homeId ?? _defaultHomeId);

    if (homeId != null) {
      try {
        final nodes =
            await ref.read(nodeServiceProvider).listNodesByHome(homeId);
        if (mounted && nodes.isNotEmpty) {
          final raw = nodes.first['id'] ??
              nodes.first['node_id'] ??
              nodes.first['nodeId'];
          final id = raw?.toString();
          if (id != null && id.isNotEmpty) setState(() => _nodeId = id);
        }
      } catch (_) {
        // No nodes (or offline) — Telemetry tile falls back to the device list.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final emailAsync = ref.watch(_profileEmailProvider);
    final queuedCount = ref.watch(commandQueueProvider).length;
    final profileImage = ref.watch(profileImageProvider);

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: V3Spacing.xxl),
          children: [
            SHEAppBar(title: l?.moreTitle ?? 'More', large: true),

            // ---- identity header ----
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.md),
              child: Row(
                children: [
                  profileImage != null
                      ? ClipOval(
                          child: Image.memory(
                            profileImage!,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                          ),
                        )
                      : const SHEAvatar(name: 'SHE', size: 56),
                  const SizedBox(width: V3Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l?.dashboard ?? 'My Home',
                          style: TextStyle(
                            color: V3Colors.ink,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        emailAsync.when(
                          loading: () => Text(
                            'Loading…',
                            style: TextStyle(
                                color: V3Colors.dim,
                                fontSize: V3Typography.meta),
                          ),
                          error: (_, __) => const SizedBox.shrink(),
                          data: (email) => Text(
                            email ?? 'Addis Ababa, Ethiopia',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: V3Colors.text2,
                              fontSize: V3Typography.meta,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ---- Account ----
            _sectionHeader('Account'),
            _tile(
              icon: Icons.person_outline,
              title: 'Profile',
              subtitle: 'Your account, password & details',
              onTap: () => context.push('/profile'),
            ),
            _tile(
              icon: Icons.workspace_premium,
              iconColor: V3Colors.warning,
              title: 'Subscription',
              subtitle: 'Plan, billing & Premium',
              onTap: () => context.push('/payments/B2C_PREMIUM'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- Devices ----
            _sectionHeader('Devices'),
            _tile(
              icon: Icons.router_outlined,
              title: 'Parent devices',
              subtitle: 'Every board provisioned in this home',
              onTap: () =>
                  context.push('/parent-devices?homeId=$_homeId'),
            ),
            _tile(
              icon: Icons.group_outlined,
              title: 'Members',
              subtitle: 'People with access to this home',
              onTap: () => context.push('/home/$_homeId/members'),
            ),
            _tile(
              icon: Icons.admin_panel_settings_outlined,
              title: 'Local admin',
              subtitle: 'Server & local Wi-Fi control',
              onTap: () => context.push('/local-admin'),
            ),
            // Local-first control (2026-10-28). Reachable while signed in too —
            // the whole point is that the board can be driven over Wi-Fi even
            // when the cloud is unreachable, so this must never depend on it.
            _tile(
              icon: Icons.wifi_tethering,
              title: 'Local control',
              subtitle: 'Control the board directly over Wi-Fi',
              onTap: () => context.push('/local'),
            ),
            _tile(
              icon: Icons.system_update_alt,
              title: 'Firmware',
              subtitle: 'OTA rollouts & board updates',
              onTap: () =>
                  context.push('/ota?homeId=$_homeId&admin=true'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- Control (offline queue — not removed) ----
            _sectionHeader('Control'),
            _tile(
              icon: Icons.schedule,
              title: 'Queued commands',
              subtitle: queuedCount == 0
                  ? "Waiting to send when you're back online"
                  : '$queuedCount waiting to send',
              onTap: () => context.push('/queued'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- Preferences ----
            _sectionHeader('Preferences'),
            _tile(
              icon: Icons.language,
              title: 'Language',
              subtitle: ref.watch(localeProvider).languageCode == 'am'
                  ? 'አማርኛ (Amharic)' : 'English',
              onTap: () => _showLanguageDialog(context, ref),
            ),
            _tile(
              icon: Icons.dark_mode,
              title: 'Theme',
              subtitle: ref.watch(themeModeProvider) == ThemeMode.light
                  ? 'Light' : 'Dark',
              onTap: () => _showThemeDialog(context, ref),
            ),
            _tile(
              icon: Icons.notifications_none,
              title: 'Alerts',
              subtitle: 'Offline, firmware & health notices',
              onTap: () => context.push('/notifications'),
            ),
            _tile(
              icon: Icons.insights_outlined,
              title: 'Telemetry',
              subtitle: _nodeId != null
                  ? 'Sensor & energy history for your boards'
                  : 'Pick a device to view its history',
              onTap: () => context.push(_nodeId != null
                  ? '/node/$_nodeId/telemetry'
                  : '/devices?homeId=$_homeId'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- Security ----
            _sectionHeader('Security'),
            _tile(
              icon: Icons.security,
              iconColor: V3Colors.success,
              title: 'Two-Factor Authentication',
              subtitle: 'Add a 6-digit code when you sign in',
              onTap: () => context.push('/settings/mfa'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- Voice & Robi ----
            _sectionHeader('Voice & Robi'),
            // Self-contained wake-word switch (same widget the Settings screen
            // uses) — gives the "Robi" entry a live toggle instead of a dead row.
            const RobiWakeTile(),
            _tile(
              icon: Icons.record_voice_over,
              title: 'Voice language',
              subtitleWidget: ref.watch(_voiceLocaleProvider).when(
                    loading: () => const Text('…'),
                    error: (_, __) =>
                        const Text('Auto (follow app language)'),
                    data: (v) => Text(v == 'en'
                        ? 'English'
                        : v == 'am'
                            ? 'አማርኛ (Amharic)'
                            : 'Auto (follow app language)'),
                  ),
              onTap: () => _showVoiceLanguageDialog(context, ref),
            ),
            _tile(
              icon: Icons.mic_none,
              title: 'Voice control',
              subtitle: 'Hold to speak, release to send',
              onTap: () => context.push('/voice'),
            ),
            _tile(
              icon: Icons.list_alt_outlined,
              title: 'Voice commands',
              subtitle: 'Everything you can say to Robi',
              onTap: () => context.push('/voice-commands'),
            ),
            const Divider(indent: 16, endIndent: 16),

            // ---- About ----
            _sectionHeader('About'),
            _tile(
              icon: Icons.info_outline,
              iconColor: V3Colors.textSecondary,
              title: 'Version',
              subtitle: 'SHE V3 — 3.0.0',
              enabled: false,
              trailing: null,
            ),
            const SizedBox(height: V3Spacing.md),

            // ---- Logout ----
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: V3Spacing.lg),
              child: ElevatedButton(
                onPressed: () async {
                  await ref.read(authServiceProvider).logout();
                  if (context.mounted) context.go('/login');
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: V3Colors.error.withValues(alpha: 0.15),
                  foregroundColor: V3Colors.error,
                ),
                child: const Text('Logout'),
              ),
            ),
            const SizedBox(height: V3Spacing.xl),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(
            left: V3Spacing.lg, top: V3Spacing.md, bottom: V3Spacing.xs),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: V3Colors.textSecondary,
            fontSize: V3Typography.overlineSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _tile({
    required IconData icon,
    Color? iconColor,
    required String title,
    String? subtitle,
    Widget? subtitleWidget,
    Widget? trailing,
    VoidCallback? onTap,
    bool enabled = true,
  }) =>
      ListTile(
        enabled: enabled,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: (iconColor ?? V3Colors.primary).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(V3Radius.full),
          ),
          child: Icon(icon, color: iconColor ?? V3Colors.primary, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: V3Colors.ink,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: subtitleWidget ??
            (subtitle == null
                ? null
                : Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: V3Colors.textSecondary,
                      fontSize: V3Typography.meta,
                    ),
                  )),
        trailing:
            trailing ?? Icon(Icons.chevron_right, color: V3Colors.textSecondary),
        onTap: onTap,
      );

  void _showVoiceLanguageDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(_voiceLocaleProvider).valueOrNull;

    showDialog(
      context: context,
      builder: (dialogContext) {
        Widget check(bool on) =>
            on ? Icon(Icons.check, color: V3Colors.primary) : const SizedBox.shrink();
        Future<void> choose(String? value) async {
          await SecureStorage.saveVoiceLocale(value);
          ref.invalidate(_voiceLocaleProvider);
          if (dialogContext.mounted) Navigator.pop(dialogContext);
        }

        return AlertDialog(
          title: const Text('Voice language'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Auto (follow app language)'),
                leading: check(current == null),
                onTap: () => choose(null),
              ),
              ListTile(
                title: const Text('English'),
                leading: check(current == 'en'),
                onTap: () => choose('en'),
              ),
              ListTile(
                title: const Text('አማርኛ (Amharic)'),
                leading: check(current == 'am'),
                onTap: () => choose('am'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showLanguageDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Language'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('አማርኛ (Amharic)'),
              leading: ref.watch(localeProvider).languageCode == 'am'
                  ? Icon(Icons.check, color: V3Colors.primary)
                  : null,
              onTap: () async {
                ref.read(localeProvider.notifier).state = const Locale('am');
                await SecureStorage.saveLocale('am');
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('English'),
              leading: ref.watch(localeProvider).languageCode == 'en'
                  ? Icon(Icons.check, color: V3Colors.primary)
                  : null,
              onTap: () async {
                ref.read(localeProvider.notifier).state = const Locale('en');
                await SecureStorage.saveLocale('en');
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Dark/light switch (ADR-009 dark-first + optional light mode).
  void _showThemeDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Dark'),
              leading: ref.watch(themeModeProvider) == ThemeMode.dark
                  ? Icon(Icons.check, color: V3Colors.primary)
                  : null,
              onTap: () async {
                ref.read(themeModeProvider.notifier).state = ThemeMode.dark;
                await SettingsStore.setThemeMode('dark');
                if (context.mounted) Navigator.pop(context);
              },
            ),
            ListTile(
              title: const Text('Light'),
              leading: ref.watch(themeModeProvider) == ThemeMode.light
                  ? Icon(Icons.check, color: V3Colors.primary)
                  : null,
              onTap: () async {
                ref.read(themeModeProvider.notifier).state = ThemeMode.light;
                await SettingsStore.setThemeMode('light');
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
