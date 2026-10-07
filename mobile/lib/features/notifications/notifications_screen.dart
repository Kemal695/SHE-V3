// =============================================================================
// SHE V3 — Notifications screen (design sheet screen 15)
// =============================================================================
// Layout ported from the sheet: back + title, a System / Devices / Security
// filter row, then a card per notification with a tinted icon tile, headline,
// supporting line and an unread dot.
//
// The list comes from `notificationStoreProvider`, which is fed by the live
// WebSocket events the backend actually emits (see notification_store.dart).
// Node names are resolved here rather than at event time, because `node.presence`
// carries only a nodeId.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';
import '../dashboard/dashboard_screen.dart' show homeNodesProvider;
import '../device_detail/node_service.dart';
import 'notification_store.dart';

/// Resolves the user's first home so node names can be looked up.
///
/// Same discovery pattern the Devices and More screens use; returns '' until it
/// resolves, which simply means names fall back to their generic titles.
final _firstHomeIdProvider = FutureProvider<String>((ref) async {
  try {
    final homes = await ref.read(nodeServiceProvider).listHomes();
    if (homes.isEmpty) return '';
    return (homes.first['id'] ?? homes.first['home_id'])?.toString() ?? '';
  } catch (_) {
    return '';
  }
});

/// nodeId -> display name, built from the home's node list.
final _nodeNamesProvider =
    FutureProvider.family<Map<String, String>, String>((ref, homeId) async {
  if (homeId.isEmpty) return const {};
  try {
    final nodes = await ref.watch(homeNodesProvider(homeId).future);
    final out = <String, String>{};
    for (final n in nodes) {
      final id = n['id']?.toString();
      if (id == null) continue;
      final name = n['display_name']?.toString() ??
          n['name']?.toString() ??
          n['node_id']?.toString();
      if (name != null && name.isNotEmpty) out[id] = name;
    }
    return out;
  } catch (_) {
    return const {};
  }
});

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key, this.homeId});

  final String? homeId;

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// 'all' | 'system' | 'devices' | 'security'
  String _filter = 'all';

  bool _matches(AppNotification n) => switch (_filter) {
        'system' => n.category == NotificationCategory.system,
        'devices' => n.category == NotificationCategory.devices,
        'security' => n.category == NotificationCategory.security,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final all = ref.watch(notificationStoreProvider);
    final unread = ref.watch(unreadNotificationCountProvider);

    // Resolve the home (either given or discovered), then the node names.
    final homeId = widget.homeId?.isNotEmpty == true
        ? widget.homeId!
        : ref.watch(_firstHomeIdProvider).valueOrNull ?? '';
    final nodeNames = ref.watch(_nodeNamesProvider(homeId)).valueOrNull ?? const {};

    final list = all.where(_matches).toList();

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SHEAppBar(
              title: l?.notifications ?? 'Notifications',
              subtitle: unread == 0
                  ? null
                  : '$unread ${l?.unread ?? 'unread'}',
              onBack: () => context.pop(),
              trailing: all.isEmpty
                  ? null
                  : SHEIconButton(
                      icon: Icons.done_all,
                      semanticLabel: l?.markAllRead ?? 'Mark all read',
                      onPressed: () =>
                          ref.read(notificationStoreProvider.notifier).markAllRead(),
                    ),
            ),

            // ---- filter row ----
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                    horizontal: V3Spacing.md, vertical: 4),
                children: [
                  for (final f in const [
                    ('all', 'All'),
                    ('system', 'System'),
                    ('devices', 'Devices'),
                    ('security', 'Security'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: V3Spacing.sm),
                      child: SHEFilterChip(
                        label: f.$2,
                        active: _filter == f.$1,
                        onTap: () => setState(() => _filter = f.$1),
                      ),
                    ),
                ],
              ),
            ),

            Expanded(
              child: list.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SHEEmptyState(
                          icon: Icons.notifications_none,
                          tone: V3Colors.dim,
                          title: all.isEmpty
                              ? (l?.noNotifications ?? 'No notifications yet')
                              : 'Nothing in this filter',
                          body: all.isEmpty
                              ? 'Device, energy and security alerts will appear here.'
                              : 'Try a different category.',
                        ),
                      ],
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(V3Spacing.md,
                          V3Spacing.sm, V3Spacing.md, V3Spacing.xxl),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final n = list[i];
                        return _NotificationTile(
                          n: n,
                          // Substitute the real node name where we have one.
                          resolvedTitle: _titleFor(n, nodeNames),
                          onTap: () => ref
                              .read(notificationStoreProvider.notifier)
                              .markRead(n.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Prefers the node's real name over the generic WS title.
  String _titleFor(AppNotification n, Map<String, String> nodeNames) {
    if (n.kind != 'presence') return n.title;
    final name = n.nodeId == null ? null : nodeNames[n.nodeId];
    if (name == null || name.isEmpty) return n.title;
    return n.title == 'Device offline'
        ? '$name is offline'
        : '$name is back online';
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.n,
    required this.resolvedTitle,
    required this.onTap,
  });

  final AppNotification n;
  final String resolvedTitle;
  final VoidCallback onTap;

  /// Icon + tint per origin, mirroring the sheet's coloured icon tiles.
  (IconData, Color) get _visual => switch (n.kind) {
        'presence' => (Icons.devices_other, V3Colors.primary),
        'ota' => (Icons.system_update_alt, V3Colors.warningAlt),
        'subscription' => (Icons.workspace_premium, V3Colors.successAlt),
        'security' => (Icons.shield_outlined, V3Colors.errorAlt),
        _ => (Icons.notifications_none, V3Colors.text2),
      };

  @override
  Widget build(BuildContext context) {
    final (icon, tint) = _visual;

    return SHECard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      // Unread rows sit on the raised surface so they read as "new" at a glance.
      raised: !n.read,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
            child: Icon(icon, size: 19, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  resolvedTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: n.read ? FontWeight.w500 : FontWeight.w700,
                  ),
                ),
                if (n.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    n.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: V3Colors.dim,
                      fontSize: V3Typography.meta,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  _relativeTime(n.at),
                  style: const TextStyle(
                    color: V3Colors.dim,
                    fontSize: V3Typography.micro,
                  ),
                ),
              ],
            ),
          ),
          if (!n.read) ...[
            const SizedBox(width: V3Spacing.sm),
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 4),
              decoration: const BoxDecoration(
                color: V3Colors.primary,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "10:45 AM" today, "Yesterday", else a short date.
  String _relativeTime(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(t.year, t.month, t.day);
    final diff = today.difference(that).inDays;

    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    final time = '$h:${t.minute.toString().padLeft(2, '0')} $ampm';

    if (diff == 0) return time;
    if (diff == 1) return 'Yesterday · $time';
    if (diff < 7) return '$diff days ago';
    return '${t.day}/${t.month}/${t.year}';
  }
}
