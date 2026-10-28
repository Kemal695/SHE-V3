// =============================================================================
// SHE V3 — Parent devices (nodes)
// =============================================================================
// The list of provisioned boards for the active home. Reached from
// Settings → Parent devices, and from the dashboard's edit (manage) screen.
//
// Boards are listed here. The board-detail page (/node/:id) was removed from
// this screen (the user did not want it), so tapping a board now opens the
// user's own Devices page (/devices) instead of a per-board view. This screen
// stays the "which boards do I own?" level plus the entry point for adding
// nodes; reaching the actual devices is one tap away on each board row.
//
// PORTED FAITHFULLY from the desktop repo (SHE-V3-main) on 2026-10-03.
// The desktop source used `context.v3` (a V3Palette ThemeExtension) and the
// `activeHomeIdProvider` / `homeNodesProvider` providers. In this mobile app
// those resolve via `v3_palette_shim.dart` (bridges context.v3 onto the
// V3Colors.* getters) and the providers already live in `active_home.dart` /
// `dashboard_screen.dart`. No color or spacing literals were re-typed.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/theme/v3_palette_shim.dart';
import '../../core/widgets/sku_icon.dart';
import '../../core/network/active_home.dart';
import '../dashboard/dashboard_screen.dart' show homeNodesProvider;

class ParentDevicesScreen extends ConsumerWidget {
  /// The home to list. Empty means "resolve it" — the caller (Settings) does not
  /// always know it, and the dashboard supplies it explicitly.
  final String homeId;

  const ParentDevicesScreen({super.key, this.homeId = ''});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // An explicit homeId wins (the dashboard passes the one it is showing);
    // otherwise fall back to the home the app has already resolved.
    final resolved =
        homeId.isNotEmpty ? homeId : (ref.watch(activeHomeIdProvider) ?? '');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.v3.textPrimary),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go('/dashboard'),
        ),
        title: const Text('Parent devices'),
        actions: [
          IconButton(
            icon: Icon(Icons.add, color: context.v3.primary),
            tooltip: 'Add Device',
            onPressed: () => context.push('/provisioning'),
          ),
        ],
      ),
      body: SafeArea(
        child: resolved.isEmpty
            ? _buildNoHome(context)
            : _buildList(context, ref, resolved),
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, String homeId) {
    final nodesAsync = ref.watch(homeNodesProvider(homeId));

    return RefreshIndicator(
      color: context.v3.primary,
      onRefresh: () => ref.refresh(homeNodesProvider(homeId).future),
      child: nodesAsync.when(
        loading: () => Center(
          child: CircularProgressIndicator(
              color: context.v3.primary, strokeWidth: 3),
        ),
        error: (err, _) => _buildError(context, ref, homeId, err),
        data: (nodes) => nodes.isEmpty
            ? _buildEmpty(context)
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(V3Spacing.md),
                children: [
                  Text(
                    '${nodes.length} device(s) in this home',
                    style: TextStyle(
                      color: context.v3.textSecondary,
                      fontSize: V3Typography.captionSize,
                    ),
                  ),
                  const SizedBox(height: V3Spacing.sm),
                  ...nodes.map((n) => _NodeTile(node: n, homeId: homeId)),
                  const SizedBox(height: V3Spacing.lg),
                ],
              ),
      ),
    );
  }

  Widget _buildNoHome(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(V3Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.home_outlined,
                size: 48, color: context.v3.textSecondary),
            const SizedBox(height: V3Spacing.md),
            Text('No home loaded yet',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: V3Spacing.sm),
            Text('Open the dashboard once, then come back here.',
                style: TextStyle(color: context.v3.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: V3Spacing.lg),
            ElevatedButton(
              onPressed: () => context.go('/dashboard'),
              child: const Text('Go to dashboard'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: context.v3.surface,
                    borderRadius: BorderRadius.circular(V3Radius.xl),
                  ),
                  child: Icon(Icons.router_outlined,
                      size: 40, color: context.v3.textSecondary),
                ),
                const SizedBox(height: V3Spacing.lg),
                Text('No devices yet',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: V3Spacing.sm),
                Text('Add your first SHE device to get started',
                    style: TextStyle(color: context.v3.textSecondary),
                    textAlign: TextAlign.center),
                const SizedBox(height: V3Spacing.xl),
                ElevatedButton.icon(
                  onPressed: () => context.push('/provisioning'),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Device'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(
      BuildContext context, WidgetRef ref, String homeId, Object err) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off,
                    size: 56, color: context.v3.textSecondary),
                const SizedBox(height: V3Spacing.lg),
                Text('Could not load your devices',
                    style: Theme.of(context).textTheme.headlineMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: V3Spacing.sm),
                Text(apiErrorMessage(err),
                    style: TextStyle(
                        color: context.v3.textSecondary,
                        fontSize: V3Typography.captionSize),
                    textAlign: TextAlign.center),
                const SizedBox(height: V3Spacing.lg),
                ElevatedButton.icon(
                  onPressed: () => ref.invalidate(homeNodesProvider(homeId)),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One provisioned board. Tapping it opens the user's own Devices page
/// (`/devices`) — the R24 board-detail page was removed from this screen, so a
/// board is just an entry point to "my devices", not its own detail view.
class _NodeTile extends StatelessWidget {
  final Map<String, dynamic> node;
  final String homeId;

  const _NodeTile({required this.node, required this.homeId});

  @override
  Widget build(BuildContext context) {
    final id = node['id']?.toString() ?? '';
    final name = (node['name'] ?? node['node_id'] ?? 'Device').toString();
    final nodeId = (node['node_id'] ?? '').toString();
    final sku = (node['sku'] ?? 'SHE-R8').toString();
    final isOnline = node['is_online'] == true;
    final online = isOnline ? context.v3.success : context.v3.textSecondary;

    return Card(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
            horizontal: V3Spacing.md, vertical: V3Spacing.xs),
        leading: Icon(iconForSku(sku), size: 28, color: context.v3.primary),
        title: Row(
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.v3.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: V3Typography.bodySize,
                ),
              ),
            ),
            const SizedBox(width: V3Spacing.sm),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: online, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              isOnline ? 'Online' : 'Offline',
              style: TextStyle(
                  color: online, fontSize: V3Typography.captionSize),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            nodeId.isEmpty
                ? '$sku · tap for your devices'
                : '$sku · $nodeId',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: context.v3.textSecondary,
                fontSize: V3Typography.captionSize),
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: context.v3.textSecondary),
        // The board detail page (R24) was removed from this screen; tapping a
        // board now opens the user's own Devices page instead.
        // IMPORTANT: use `go`, not `push`. `/devices` is a StatefulShellRoute
        // branch; pushing it from this detail route (which lives OUTSIDE the
        // shell) stacks a shell route on top of the shell and corrupts the
        // branch indices, so a later bottom-nav tap resolves to the wrong tab
        // (e.g. Devices opens More). `go` replaces the route and cleanly
        // switches the shell's active branch.
        onTap: id.isEmpty ? null : () => context.go('/devices?homeId=$homeId'),
      ),
    );
  }
}

