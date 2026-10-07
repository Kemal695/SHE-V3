// =============================================================================
// SHE V3 — More screen (prototype `more.tsx` · profile / account hub)
// =============================================================================
// The fifth tab: identity, plan, and the entry points that used to be crammed
// into the dashboard app bar (voice, add device, settings, members).
//
// Every row navigates to a route that ALREADY EXISTS — this screen adds no new
// destinations, it only surfaces them. That is deliberate: the old dashboard
// put Voice/Settings/Add behind three identical icon buttons and buried
// Automations/Settings entirely, which is what this tab fixes.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/dio_client.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';

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

class MoreScreen extends ConsumerStatefulWidget {
  const MoreScreen({super.key});

  @override
  ConsumerState<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends ConsumerState<MoreScreen> {
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';
  String _homeId = _defaultHomeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
  }

  Future<void> _resolveHome() async {
    try {
      final res = await ref.read(dioProvider).get('/api/v3/homes');
      final homes = (res.data['data'] as List<dynamic>? ?? const []);
      if (homes.isNotEmpty && mounted) {
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) setState(() => _homeId = id);
      }
    } catch (_) {
      // Keep the seed; the members route tolerates it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final emailAsync = ref.watch(_profileEmailProvider);

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
                  const SHEAvatar(name: 'SHE', size: 56),
                  const SizedBox(width: V3Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l?.dashboard ?? 'My Home',
                          style: const TextStyle(
                            color: V3Colors.ink,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        emailAsync.when(
                          loading: () => const Text(
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
                            style: const TextStyle(
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

            // ---- premium banner ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
              child: SHECard(
                onTap: () => context.push('/payments/B2C_PREMIUM'),
                padding: const EdgeInsets.all(V3Spacing.md),
                color: V3Colors.heroMid,
                glow: true,
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: V3Colors.warningAlt.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(V3Radius.md),
                      ),
                      child: const Icon(Icons.workspace_premium,
                          size: 20, color: V3Colors.warningAlt),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'SHE Premium',
                            style: TextStyle(
                              color: V3Colors.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Unlock automations, energy insights and more',
                            style: TextStyle(
                              color: V3Colors.text2,
                              fontSize: V3Typography.meta,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right,
                        size: 20, color: V3Colors.dim),
                  ],
                ),
              ),
            ),

            const SizedBox(height: V3Spacing.lg),

            // ---- control group ----
            _GroupLabel('Control'),
            _MenuTile(
              icon: Icons.mic_none,
              title: 'Voice control',
              subtitle: 'Hold to speak, release to send',
              onTap: () => context.push('/voice'),
            ),
            _MenuTile(
              icon: Icons.add_circle_outline,
              title: l?.addDevice ?? 'Add Device',
              subtitle: 'Pair a new board over Bluetooth',
              onTap: () => context.push('/provisioning'),
            ),
            _MenuTile(
              icon: Icons.account_tree_outlined,
              title: 'Automations',
              subtitle: 'WHEN / IF / THEN rules',
              onTap: () =>
                  context.push('/automations?homeId=$_homeId'),
            ),
            _MenuTile(
              icon: Icons.auto_awesome_outlined,
              title: 'Scenes',
              subtitle: 'One-tap moods for the whole home',
              onTap: () => context.push('/scenes?homeId=$_homeId'),
            ),

            const SizedBox(height: V3Spacing.lg),

            // ---- account group ----
            _GroupLabel('Account'),
            _MenuTile(
              icon: Icons.group_outlined,
              title: l?.members ?? 'Members',
              subtitle: l?.membersSubtitle ?? 'People who can control this home',
              onTap: () => context.push('/home/$_homeId/members'),
            ),
            _MenuTile(
              icon: Icons.settings_outlined,
              title: l?.settings ?? 'Settings',
              subtitle: l?.settingsSubtitle ?? 'Language, server, account',
              onTap: () => context.push('/settings'),
            ),
            _MenuTile(
              icon: Icons.bolt_outlined,
              title: 'Energy',
              subtitle: 'Consumption and cost',
              onTap: () => context.push('/energy?homeId=$_homeId'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(V3Spacing.md, 0, V3Spacing.md, V3Spacing.sm),
      child: SHEOverline(text),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(V3Spacing.md, 0, V3Spacing.md, V3Spacing.sm),
      child: SHECard(
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: V3Colors.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(V3Radius.md),
              ),
              child: Icon(icon, size: 19, color: V3Colors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: V3Colors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: V3Colors.dim,
                      fontSize: V3Typography.meta,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: V3Colors.dim),
          ],
        ),
      ),
    );
  }
}
