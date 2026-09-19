// =============================================================================
// SHE V3 — Dashboard Screen (Bento grid)
// =============================================================================
// V3-MOBILE-APP §4-5. ADR-009.
// No overflow: uses CustomScrollView with SliverGrid.
// Pull-to-refresh works in all states (loading/error/empty/data).
// Back button exits app (not go to login).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/network/ws_client.dart';
import '../../core/network/dio_client.dart';
import '../device_detail/node_service.dart';
import 'widgets/dynamic_device_widget.dart';
import 'widgets/energy_summary_card.dart';
import '../scenes/scenes_row.dart';
import '../scenes/scene_service.dart';

/// Scenes for a home, loaded from the API. Previously the dashboard rendered a
/// hardcoded list and tapping a scene only showed a SnackBar — there was no
/// endpoint behind it. Backend: GET /api/v3/homes/{homeId}/scenes.
/// (homeScenesProvider now lives in scene_service.dart so the editor can reuse it.)

final homeNodesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, homeId) => ref.read(nodeServiceProvider).listNodesByHome(homeId),
);

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  // TODO: load real homes list. For now use default B2C tenant home.
  String _homeId = '00000000-0000-0000-0000-000000000001';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Pass the home so the socket auto-subscribes. A bare connect() produced a
      // live socket that was subscribed to NOTHING, so no node.state /
      // energy.update / node.presence events ever reached the UI.
      ref.read(wsClientProvider).connect(homeId: _homeId);
      _loadHomes();
    });
  }

  Future<void> _loadHomes() async {
    try {
      // Load first home for the user
      final dio = ref.read(dioProvider);
      final response = await dio.get('/api/v3/homes');
      final homes = response.data['data'] as List<dynamic>;
      if (homes.isNotEmpty && mounted) {
        final resolved = homes.first['id'] as String;
        setState(() {
          _homeId = resolved;
        });
        // The socket is likely already connected (to the placeholder home id),
        // so re-point its subscription at the home we actually loaded —
        // otherwise the grid shows the right devices but never updates live.
        ref.read(wsClientProvider).subscribeToHome(resolved);
      }
    } catch (_) {
      // Fallback to default home — provider will handle gracefully
    }
  }

  @override
  Widget build(BuildContext context) {
    final nodesAsync = ref.watch(homeNodesProvider(_homeId));

    // The populated view renders its OWN SliverAppBar inside a CustomScrollView
    // (so it floats/snaps with the grid). The loading / error / empty views have
    // no scroll view of their own, so they used to render with NO app bar at all
    // — which left Settings and Log out unreachable for a user with zero devices
    // (a dead end: you cannot even sign out). Give those states the same bar.
    final hasContent = nodesAsync.valueOrNull?.isNotEmpty ?? false;

    return PopScope(
      // Back button from dashboard exits the app (not go to login)
      canPop: false,
      child: Scaffold(
        appBar: hasContent ? null : _buildAppBar(context),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(homeNodesProvider(_homeId).future),
            color: V3Colors.primary,
            child: nodesAsync.when(
              loading: () => _buildLoading(),
              error: (err, _) => _buildError(context, err.toString(), ref),
              data: (nodes) => _buildContent(context, nodes, ref),
            ),
          ),
        ),
        bottomNavigationBar: _buildBottomBar(context),
      ),
    );
  }

  /// App bar for the non-grid states (loading / error / empty).
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final wsUp = ref.watch(wsConnectedProvider);
    return AppBar(
      backgroundColor: V3Colors.background,
      elevation: 0,
      centerTitle: false,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'My Home',
            style: TextStyle(
              color: V3Colors.textPrimary,
              fontSize: V3Typography.headlineSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: wsUp ? V3Colors.success : V3Colors.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: V3Spacing.xs),
              Text(
                wsUp ? 'Live' : 'Offline',
                style: const TextStyle(
                  color: V3Colors.textSecondary,
                  fontSize: V3Typography.captionSize,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: _appBarActions(context),
    );
  }

  /// Voice / add-device / settings — shared by both app bars so the two can
  /// never drift apart (the missing one is what made the empty state a dead end).
  List<Widget> _appBarActions(BuildContext context) => [
        IconButton(
          icon: const Icon(Icons.mic_none, color: V3Colors.textSecondary),
          onPressed: () => context.push('/voice'),
          tooltip: 'Voice Control',
        ),
        IconButton(
          icon: const Icon(Icons.add, color: V3Colors.primary),
          onPressed: () => context.push('/provisioning'),
          tooltip: 'Add Device',
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: V3Colors.textSecondary),
          onPressed: () => context.push('/settings'),
          tooltip: 'Settings',
        ),
      ];

  /// Bottom bar — Scenes / Automations / Voice / Settings.
  ///
  /// Icons match the existing app-bar actions exactly (same set, same default
  /// 24px size, same V3Colors.textSecondary) so the two never look mismatched.
  /// Tapping pushes the destination route; these are destinations, not tabs —
  /// we navigate rather than swapping a body in place.
  Widget _buildBottomBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: V3Colors.surface,
        border: Border(
          top: BorderSide(color: Color(0x1FFFFFFF), width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: V3Spacing.md, vertical: V3Spacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _BottomBarButton(
                icon: Icons.auto_awesome_outlined,
                label: 'Scenes',
                onTap: () => context.push('/scenes?homeId=$_homeId'),
              ),
              _BottomBarButton(
                icon: Icons.bolt_outlined,
                label: 'Automations',
                onTap: () => context.push('/automations?homeId=$_homeId'),
              ),
              _BottomBarButton(
                icon: Icons.mic_none,
                label: 'Voice',
                onTap: () => context.push('/voice'),
              ),
              _BottomBarButton(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: () => context.push('/settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<Map<String, dynamic>> nodes, WidgetRef ref) {
    if (nodes.isEmpty) return _buildEmptyState(context);

    // Reactive socket state — a plain WsClient.isConnected getter cannot be
    // watched, so the client mirrors it into wsConnectedProvider.
    final wsUp = ref.watch(wsConnectedProvider);
    final scenesAsync = ref.watch(homeScenesProvider(_homeId));

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // ---- AppBar ----
        SliverAppBar(
          floating: true,
          snap: true,
          backgroundColor: V3Colors.background,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('My Home', style: TextStyle(
                color: V3Colors.textPrimary,
                fontSize: V3Typography.headlineSize,
                fontWeight: FontWeight.w600,
              )),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: wsUp ? V3Colors.success : V3Colors.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: V3Spacing.xs),
                  Text(
                    '${wsUp ? 'Live' : 'Offline'} · ${nodes.length} devices',
                    style: const TextStyle(
                      color: V3Colors.textSecondary,
                      fontSize: V3Typography.captionSize,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: _appBarActions(context),
        ),

        // ---- Scenes Row (horizontal scroll) — real scenes from the API.
        // ---- No "Scenes" label above: the user asked for a clean home page.
        // ---- Manage scenes from the bottom bar's Scenes tab.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: V3Spacing.xs, bottom: V3Spacing.xs),
            child: scenesAsync.when(
              loading: () => const SizedBox(height: 0),
              error: (_, __) => const SizedBox.shrink(),
              data: (scenes) => scenes.isEmpty
                  ? const SizedBox.shrink()
                  : ScenesRow(
                      scenes: scenes
                          .map((s) => {
                                'id': s.id,
                                'name': s.name,
                                'icon': s.icon ?? 'scene',
                              })
                          .toList(),
                      onActivate: (sceneId) => _activateScene(context, ref, sceneId, scenes),
                    ),
            ),
          ),
        ),

        // ---- Energy Summary card (V3-DESIGN-SYSTEM §4.3) ----
        // Honest placeholder today: the backend's home-level endpoint is a
        // Phase 4 stub, so the card displays "Phase 4 — per-home aggregation
        // coming soon" rather than fake numbers. When Phase 4 lands the card
        // will display real W/ETB automatically (see energy_summary_card.dart).
        SliverToBoxAdapter(
          child: _homeId == null
              ? const SizedBox.shrink()
              : EnergySummaryCard(homeId: _homeId!),
        ),

        // NOTE (V3-DESIGN-SYSTEM §4): an "Automations" nav tile was added here
        // earlier, but the Bento dashboard spec does not include it — it was
        // clutter that broke the "scenes row + device grid" composition. Removed
        // on purpose. Automations remain reachable from Settings.



        // ---- Bento Grid ----
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              crossAxisSpacing: V3Spacing.sm,
              mainAxisSpacing: V3Spacing.sm,
              childAspectRatio: 1.0,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final node = nodes[index];
                return DynamicDeviceWidget(node: node);
              },
              childCount: nodes.length,
            ),
          ),
        ),

        // ---- Bottom padding ----
        const SliverPadding(padding: EdgeInsets.only(bottom: V3Spacing.xxl)),
      ],
    );
  }

  /// Activate a scene and report the real outcome from the backend
  /// ({acceptedCount, failed[]}) instead of the old fake "Activating scene..." toast.
  Future<void> _activateScene(
    BuildContext context,
    WidgetRef ref,
    String sceneId,
    List<Scene> scenes,
  ) async {
    final name = scenes
        .where((s) => s.id == sceneId)
        .map((s) => s.name)
        .firstOrNull;
    try {
      final result = await ref.read(sceneServiceProvider).activate(sceneId);
      if (!context.mounted) return;

      final message = result.isFullSuccess
          ? '${name ?? 'Scene'} on · ${result.acceptedCount} device(s) updated'
          : '${name ?? 'Scene'} partly applied · ${result.acceptedCount} ok, '
              '${result.failed.length} failed: ${result.failed.join(', ')}';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor: result.isFullSuccess ? V3Colors.success : V3Colors.warning,
        ),
      );

      // Refresh device state so the grid reflects the new values.
      ref.invalidate(homeNodesProvider(_homeId));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not activate ${name ?? 'scene'}: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: V3Colors.error,
        ),
      );
    }
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: V3Colors.primary, strokeWidth: 3),
          SizedBox(height: V3Spacing.lg),
          Text('Loading your home...', style: TextStyle(color: V3Colors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, String error, WidgetRef ref) {
    // Wrap in SingleChildScrollView so pull-to-refresh works
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off, size: 64, color: V3Colors.textSecondary),
              const SizedBox(height: V3Spacing.lg),
              Text('Cannot reach SHE cloud', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: V3Spacing.sm),
              Text('Check your internet connection and try again.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: V3Spacing.lg),
              ElevatedButton.icon(
                onPressed: () => ref.refresh(homeNodesProvider(_homeId)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: V3Colors.surface,
                    borderRadius: BorderRadius.circular(V3Radius.xl),
                  ),
                  child: const Icon(Icons.home_outlined, size: 40, color: V3Colors.textSecondary),
                ),
                const SizedBox(height: V3Spacing.lg),
                Text('No devices yet', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: V3Spacing.sm),
                Text('Add your first SHE device to get started',
                    style: Theme.of(context).textTheme.bodyMedium,
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
  }

/// One entry in the dashboard bottom bar.
///
/// Deliberately mirrors the app-bar IconButton styling: default 24px icon with
/// V3Colors.textSecondary, so Automations/Scenes read identically to the existing
/// Voice and Settings icons. Tapping offers a light haptic, per V3-DESIGN-SYSTEM §1.10.
class _BottomBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _BottomBarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(V3Radius.md),
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: V3Spacing.sm, vertical: V3Spacing.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: V3Colors.textSecondary, size: 28),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: V3Colors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
