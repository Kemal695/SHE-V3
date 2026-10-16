// =============================================================================
// SHE V3 — Dashboard Screen (prototype `home.tsx` · Home dashboard §7)
// =============================================================================
// RESTYLED for the SHE-V3 UI/UX redesign (2026-10-03). Layout ported from the
// prototype: greeting header, hero status card, scenes row, 2-col Bento grid,
// energy mini-card, long-press quick actions.
//
// WHAT IS UNCHANGED (this was a presentation-only rewrite — deliberate):
//   * `homeNodesProvider` — same provider, same endpoint, same family key. The
//     Devices screen and the energy tab both depend on it.
//   * The WebSocket connect + `subscribeToHome` handshake, including the M4 fix
//     where the socket is re-pointed after the real home id resolves.
//   * `_loadHomes()` and the seeded default home id.
//   * `_activateScene()` — the real POST /scenes/{id}/activate with its
//     acceptedCount / failed[] reporting.
//   * `_appBarActions()` / `_buildBottomBar` targets — now owned by AppShell.
//   * The PopScope(back = exit app) behaviour.
//
// The old file carried a hand-rolled bottom bar (Scenes/Automations/Voice/
// Settings) inside the dashboard. That is now the shell's 5-tab nav, so the
// dashboard no longer renders its own — it is a tab body, not a whole screen.
// =============================================================================

import 'package:dio/dio.dart' show Dio, BaseOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../../core/network/api_error.dart';
import '../../core/network/ws_client.dart';
import '../../core/network/dio_client.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/device_detail_screen.dart'
    show
        GroupEditResult,
        GroupEditorDialog,
        kGroupIconChoices,
        nodeDeviceGroupsProvider,
        nodeDeviceParamsProvider,
        nodeDevicesProvider;
import '../device_detail/node_service.dart';
import '../notifications/notification_store.dart';
import '../voice/voice_hold_button.dart';
import 'widgets/energy_summary_card.dart';
import '../scenes/scene_service.dart';

final homeNodesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, homeId) => ref.read(nodeServiceProvider).listNodesByHome(homeId),
);

/// Best-effort home climate reading for the status card's HVAC gauges.
///
/// Scans the home's devices for a `Temperature` / `Humidity` param (the same
/// param names the temp-sensor card and telemetry use) and returns the first
/// found. Nulls when the home has no such sensor — the gauges then render as
/// "—" placeholders, the honest state until a climate device is provisioned.
final homeClimateProvider =
    FutureProvider.family<({double? temp, double? humidity}), String>(
  (ref, homeId) async {
    final nodes = await ref.watch(homeNodesProvider(homeId).future);
    final service = ref.read(nodeServiceProvider);
    double? temp;
    double? humidity;
    for (final node in nodes) {
      final nodeId = node['id']?.toString();
      if (nodeId == null) continue;
      List<Map<String, dynamic>> devices;
      try {
        devices = await service.listDevices(nodeId);
      } catch (_) {
        continue; // one unreachable board must not blank the gauges
      }
      for (final d in devices) {
        final params = d['params'] as List<dynamic>? ?? const [];
        for (final p in params) {
          if (p is! Map) continue;
          final name = p['param_name']?.toString();
          final v = p['last_value'];
          if (name == 'Temperature' && v is num) temp ??= v.toDouble();
          if (name == 'Humidity' && v is num) humidity ??= v.toDouble();
        }
      }
      if (temp != null && humidity != null) break;
    }
    return (temp: temp, humidity: humidity);
  },
);

// -----------------------------------------------------------------------------
// Weather — current conditions for the home's city, for the dashboard's weather
// block. Sourced from Open-Meteo (keyless) via a DEDICATED Dio with no
// interceptors, so the app's JWT is never sent to a third party. Returns null
// (and the card shows a neutral placeholder) whenever it is unreachable.
// -----------------------------------------------------------------------------
typedef _WeatherNow = ({double? tempC, double? humidity, int code});

/// Addis Ababa — the app is Ethiopia-only (ADR-010).
const double _weatherLat = 9.03;
const double _weatherLon = 38.74;

final _weatherProvider = FutureProvider<_WeatherNow?>((ref) async {
  try {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
    ));
    final r = await dio.get(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': _weatherLat,
        'longitude': _weatherLon,
        'current': 'temperature_2m,relative_humidity_2m,weather_code',
        'timezone': 'Africa/Addis_Ababa',
      },
    );
    final data = r.data;
    if (data is! Map) return null;
    final cur = data['current'];
    if (cur is! Map) return null;
    return (
      tempC: (cur['temperature_2m'] as num?)?.toDouble(),
      humidity: (cur['relative_humidity_2m'] as num?)?.toDouble(),
      code: (cur['weather_code'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
});

/// WMO weather code → (icon, short label). https://open-meteo.com/en/docs
(IconData, String) _weatherVisual(int code) {
  if (code == 0) return (Icons.wb_sunny_outlined, 'Clear');
  if (code <= 3) return (Icons.wb_cloudy_outlined, 'Partly cloudy');
  if (code == 45 || code == 48) return (Icons.foggy, 'Fog');
  if (code >= 51 && code <= 57) return (Icons.grain, 'Drizzle');
  if (code >= 61 && code <= 67) return (Icons.water_drop_outlined, 'Rain');
  if (code >= 71 && code <= 77) return (Icons.ac_unit, 'Snow');
  if (code >= 80 && code <= 82) return (Icons.water_drop, 'Showers');
  if (code >= 95) return (Icons.thunderstorm_outlined, 'Thunderstorm');
  return (Icons.wb_cloudy_outlined, 'Cloudy');
}

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
      final dio = ref.read(dioProvider);
      final response = await dio.get('/api/v3/homes');
      final homes = response.data['data'] as List<dynamic>;
      if (homes.isNotEmpty && mounted) {
        final resolved = (homes.first['id'] ?? homes.first['home_id']) as String;
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
    // Watch the WS-reported Power at the TOP of build so the group cards (which
    // read it in a helper method) reliably rebuild on every device report.
    ref.watch(livePowerProvider);

    // NOTE (bugfix 2026-10-03): this screen deliberately has NO PopScope.
    //
    // It used to carry `PopScope(canPop: false)`, written when the dashboard was
    // a standalone route and Back there had to mean "exit, not go to login".
    // Under StatefulShellRoute.indexedStack that became a bug: all five branches
    // stay mounted, so this PopScope intercepted Back from EVERY tab. Blocking
    // the pop with no handler made the system fall through to the root
    // navigator, which popped the entire shell route; go_router then resolved to
    // its initialLocation (/splash -> /onboarding -> /login) — the "Back logs me
    // out" report.
    //
    // Back is now owned by a single PopScope in AppShell (app_shell.dart), which
    // is the only place that knows the tab layout. Keeping a second PopScope
    // here would double-handle the same gesture.
    return Scaffold(
      backgroundColor: V3Colors.background,
      // The floating voice button lives on the board page so a command can be
      // given while looking at the devices it controls (added previously and
      // kept).
      floatingActionButton: const VoiceHoldButton(),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => ref.refresh(homeNodesProvider(_homeId).future),
          color: V3Colors.primary,
          backgroundColor: V3Colors.surface,
          child: nodesAsync.when(
            loading: () => _buildLoading(),
            error: (err, _) => _buildError(err),
            data: (nodes) => _buildContent(nodes),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(List<Map<String, dynamic>> nodes) {
    final wsUp = ref.watch(wsConnectedProvider);
    final scenesAsync = ref.watch(homeScenesProvider(_homeId));
    final online = nodes.where((n) => n['is_online'] == true).length;
    final offline = nodes.length - online;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // ---- header (greeting + home + bell + avatar) ----
        SliverToBoxAdapter(
          child: _Header(
            online: online,
            total: nodes.length,
            // The bell used to push /more, which was simply the wrong screen.
            // Design sheet screen 15 is the real target.
            onNotifications: () => context.push('/notifications?homeId=$_homeId'),
            onProfile: () => context.push('/more'),
            hasUnread: ref.watch(unreadNotificationCountProvider) > 0,
          ),
        ),

        // ---- hero status card ----
        SliverToBoxAdapter(
          child: _HeroStatus(
            online: online,
            offline: offline,
            live: wsUp,
          ),
        ),

        // ---- weather (design sheet: dashboard carries a weather block) ----
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                V3Spacing.md, V3Spacing.md, V3Spacing.md, 0),
            child: _WeatherCard(),
          ),
        ),

        // ---- scenes row ----
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: V3Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
                  child: SHESectionHeader(
                    title: AppLocalizations.of(context)?.scenesRowTitle ??
                        'Scenes',
                    action: 'View all',
                    onAction: () => context.push('/scenes?homeId=$_homeId'),
                  ),
                ),
                const SizedBox(height: 10),
                scenesAsync.when(
                  loading: () => const SizedBox(height: 84),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (scenes) => scenes.isEmpty
                      ? const SizedBox.shrink()
                      : _ScenesRow(
                          scenes: scenes
                              .map((s) => {
                                    'id': s.id,
                                    'name': s.name,
                                    'icon': s.icon ?? 'scene',
                                  })
                              .toList(),
                          onActivate: (sceneId) =>
                              _activateScene(sceneId, scenes),
                          onManage: () =>
                              context.push('/scenes?homeId=$_homeId'),
                        ),
                ),
              ],
            ),
          ),
        ),

        // ---- devices section ----
        // No per-device list on the home page (user request 2026-10-10): the
        // dashboard shows GROUPS instead, and the Groups section below is where
        // you act on devices. This header links to the Devices tab, which is the
        // one place that lists and toggles individual devices.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                V3Spacing.md, V3Spacing.lg, V3Spacing.md, 10),
            child: SHESectionHeader(
              title: 'My Devices',
              action: 'View all',
              onAction: () => context.push('/devices?homeId=$_homeId'),
            ),
          ),
        ),

        if (nodes.isEmpty)
          SliverToBoxAdapter(
            child: SHEEmptyState(
              icon: Icons.home_outlined,
              title: 'No devices yet',
              body: 'Add your first SHE device to get started',
              actionLabel: 'Add Device',
              onAction: () => context.push('/provisioning'),
            ),
          )
        else
          // Indoor climate (temperature + humidity) from the home's sensors.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
              child: _ClimateCard(homeId: _homeId),
            ),
          ),

        // ---- groups section ----
        // Moved here from the Devices tab: a group spans the whole home, so it
        // belongs on the home dashboard rather than buried under one board.
        // No SHESectionHeader here — GroupsSection draws its own "GROUPS" header
        // and "New group" button, and a second one would read as a duplicate.
        for (final node in nodes)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  V3Spacing.md, V3Spacing.lg, V3Spacing.md, 0),
              child: _homeGroupsCard(node),
            ),
          ),

        // ---- energy mini card ----
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                V3Spacing.md, V3Spacing.lg, V3Spacing.md, 0),
            child: _EnergyMiniCard(homeId: _homeId),
          ),
        ),

        const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
      ],
    );
  }

  /// One premium card PER GROUP, each opening its own detail page.
  ///
  /// This replaces the shared GroupsSection that used to sit here: that rendered
  /// every group as a plain row inside one block, and its per-device control was
  /// hidden behind an inline expansion. The user asked for the Scenes pattern
  /// instead — a card per item, and a page of its own when you tap it.
  ///
  /// GroupsSection is still used on the node detail page; this is additive.
  Widget _homeGroupsCard(Map<String, dynamic> node) {
    final nodeId = node['id']?.toString();
    if (nodeId == null) return const SizedBox.shrink();

    final groupsAsync = ref.watch(nodeDeviceGroupsProvider(_homeId));
    final raw = ref.watch(nodeDevicesProvider(nodeId)).valueOrNull ??
        const <Map<String, dynamic>>[];

    return groupsAsync.when(
      loading: () => const SizedBox.shrink(),
      // A group failure must not take the whole dashboard down with it.
      error: (_, __) => const SizedBox.shrink(),
          data: (groups) {
            if (groups.isEmpty) return const SizedBox.shrink();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: V3Spacing.sm),
                  child: SHESectionHeader(
                    title: 'Groups',
                    action: 'New',
                    onAction: () => _openGroupEditor(raw),
                  ),
                ),
                // 2-up grid, the same layout the Scenes page uses — the user
                // asked for the identical card, so the tile is _sceneCard's
                // shape verbatim (icon tile, name, count, corner bloom).
                GridView.count(
                  // 2-up on phones, 3-up on tablets, 4-up on foldables
                  // (audit screens #24/#25).
                  crossAxisCount:
                      switch (V3Breakpoints.sizeClass(context)) {
                    V3SizeClass.compact => 2,
                    V3SizeClass.medium => 3,
                    V3SizeClass.expanded => 4,
                  },
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: V3Spacing.sm,
                  crossAxisSpacing: V3Spacing.sm,
                  childAspectRatio: 1.02,
                  children: [
                    for (final g in groups) _groupCard(nodeId, g, raw),
                  ],
                ),
              ],
            );
          },
    );
  }

  Widget _groupCard(
    String nodeId,
    Map<String, dynamic> group,
    List<Map<String, dynamic>> raw,
  ) {
    final id = group['id'].toString();
    final name = group['name']?.toString() ?? 'Group';
    final rawIds =
        (group['device_ids'] ?? group['deviceIds']) as List<dynamic>? ??
            const <dynamic>[];
    final ids = rawIds.map((e) => e.toString()).toList();

    // Resolve members from the list already loaded, so the card can show a real
    // on-count and the right icon without another round trip.
    final members =
        raw.where((d) => ids.contains(d['id'].toString())).toList();

    // Live Power per member — the provider `ws_client` invalidates on every
    // node.state event, so the count follows the board rather than the last tap.
    var onCount = 0;
    var anySocket = false;
    var anyLight = false;
    for (final d in members) {
      final did = d['id'].toString();
      final label = (d['device_name'] ?? d['display_name'] ?? '')
          .toString()
          .toLowerCase();
      if (label.contains('socket') || label.contains('outlet')) {
        anySocket = true;
      } else if (label.contains('light') || label.contains('lamp')) {
        anyLight = true;
      }
      // Prefer the WS-reported value (instant); fall back to the REST param when
      // no event has arrived for this device yet.
      final ws = ref.watch(livePowerProvider)[did];
      if (ws == true) {
        onCount++;
      } else if (ws == null) {
        ref.watch(nodeDeviceParamsProvider('$nodeId|$did')).whenData((params) {
          final p = params.cast<Map<String, dynamic>?>().firstWhere(
                (x) => x?['param_name'] == 'Power',
                orElse: () => null,
              );
          if (p != null && p['last_value'] == true) onCount++;
        });
      }
    }

    final allOn = members.isNotEmpty && onCount == members.length;
    // A folder with a plug reads as a socket group, a bulb as a light group —
    // so the icon says what the group actually is — UNLESS the group has an
    // explicit icon chosen in the editor, which wins over the derivation.
    final String? chosenIconKey = group['icon']?.toString();
    final icon = (chosenIconKey != null &&
            chosenIconKey != 'auto' &&
            kGroupIconChoices.containsKey(chosenIconKey))
        ? kGroupIconChoices[chosenIconKey]!
        : (anySocket && !anyLight
            ? Icons.power_outlined
            : anyLight && !anySocket
                ? Icons.lightbulb_outline
                : Icons.folder_special_outlined);

    // Deliberately the same visual language as the Scenes page's _sceneCard:
    // vertical tile, 44px icon, name, count, radial bloom in the corner, and a
    // primary border + glow when everything in the group is on. Tapping opens the
    // group's own page, exactly as a scene card opens the scene detail.
    return GestureDetector(
      onTap: () => context.push(
        '/groups/$id?homeId=$_homeId&nodeId=$nodeId'
        '&name=${Uri.encodeComponent(name)}',
      ),
      child: Container(
        decoration: BoxDecoration(
          color: allOn
              ? V3Colors.primary.withValues(alpha: 0.15)
              : V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.xl),
          border: Border.all(
            color: allOn
                ? V3Colors.primary.withValues(alpha: 0.6)
                : V3Colors.border,
          ),
          boxShadow: allOn
              ? [
                  BoxShadow(
                    color: V3Colors.primary.withValues(alpha: 0.45),
                    blurRadius: 30,
                    spreadRadius: -6,
                  ),
                ]
              : null,
        ),
        child: Stack(
          children: [
            Positioned(
              right: -24,
              top: -32,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    V3Colors.primary.withValues(alpha: 0.4),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(V3Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: allOn
                          ? V3Colors.primary
                          : V3Colors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(V3Radius.md),
                    ),
                    child: Icon(icon,
                        size: 22,
                        color: allOn ? V3Colors.night : V3Colors.primary),
                  ),
                  const Spacer(),
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: V3Colors.ink,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '${members.length} device(s) · $onCount on',
                    style:
                        const TextStyle(color: V3Colors.dim, fontSize: 11),
                  ),
                ],
              ),
            ),
            // Same top-right affordance the scene cards carry: a ⋮ menu for
            // Edit / Delete. The card itself is the "open the detail page"
            // gesture; the menu has its own hit zone so tapping it does not
            // navigate.
            Positioned(
              right: 0,
              top: 0,
              child: PopupMenuButton<String>(
                tooltip: 'Manage group',
                icon: Icon(
                  Icons.more_vert,
                  size: 18,
                  color: allOn ? V3Colors.primary : V3Colors.dim,
                ),
                color: V3Colors.surface2,
                onSelected: (v) {
                  if (v == 'edit') _openGroupEditor(raw, existing: group);
                  if (v == 'delete') _deleteGroup(group);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Open the shared [GroupEditorDialog] against this node's devices. Used by
  /// both the dashboard "New" action and the per-card "Edit" menu.
  ///
  /// The dialog returns a [GroupEditResult] with the new name + device ids;
  /// we POST/PATCH the home-scoped groups endpoint, then invalidate so the home
  /// cards (and the node detail page, which watches the same provider) re-fetch.
  void _openGroupEditor(
    List<Map<String, dynamic>> devices, {
    Map<String, dynamic>? existing,
  }) {
    showDialog<GroupEditResult>(
      context: context,
      builder: (_) => GroupEditorDialog(
        devices: devices,
        existing: existing,
      ),
    ).then((result) async {
      if (result == null || !mounted) return;
      try {
        final svc = ref.read(nodeServiceProvider);
        if (existing == null) {
          await svc.createDeviceGroup(
            _homeId,
            result.name,
            result.deviceIds,
            icon: result.icon,
            image: result.image,
          );
        } else {
          await svc.updateDeviceGroup(
            existing['id'].toString(),
            result.name,
            result.deviceIds,
            icon: result.icon,
            image: result.image,
          );
        }
        if (!mounted) return;
        ref.invalidate(nodeDeviceGroupsProvider(_homeId));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(existing == null
              ? '${result.name} created · ${result.deviceIds.length} device(s)'
              : '${result.name} updated'),
        ));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(apiErrorMessage(e)),
          backgroundColor: V3Colors.errorAlt,
        ));
      }
    });
  }

  /// Confirm + DELETE a group. Returns from the snackbar so the user knows it
  /// succeeded; surfaces a clean error otherwise.
  Future<void> _deleteGroup(Map<String, dynamic> group) async {
    final name = group['name']?.toString() ?? 'this group';
    final id = group['id'].toString();
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: V3Colors.surface,
            title: const Text('Delete group?',
                style: TextStyle(color: V3Colors.ink)),
            content: Text(
                'This removes "$name". Devices are not changed.',
                style: const TextStyle(color: V3Colors.text2)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete',
                    style: TextStyle(color: V3Colors.errorAlt)),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await ref.read(nodeServiceProvider).deleteDeviceGroup(id);
      if (!mounted) return;
      ref.invalidate(nodeDeviceGroupsProvider(_homeId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$name deleted'),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.errorAlt,
      ));
    }
  }

  /// Long-press quick actions — the redesign keeps V3-DESIGN-SYSTEM §1.10's
  /// radial menu on the grid; this is a bottom sheet variant reachable from
  /// every tile, matching the prototype's QuickActionSheet.
  void _showQuickActions(Map<String, dynamic> node) {
    final nodeId = node['id']?.toString() ?? '';
    final name = node['name']?.toString() ??
        node['node_id']?.toString() ??
        'Device';
    HapticFeedback.mediumImpact();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: V3Colors.surface2,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: V3Colors.borderStrong)),
        ),
        padding: EdgeInsets.fromLTRB(
          V3Spacing.lg,
          V3Spacing.sm,
          V3Spacing.lg,
          V3Spacing.xl + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: V3Colors.fillStrong,
                borderRadius: BorderRadius.circular(V3Radius.full),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              name,
              style: const TextStyle(
                color: V3Colors.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: V3Spacing.lg),
            Row(
              children: [
                _QuickAction(
                  icon: Icons.tune,
                  label: 'Devices',
                  onTap: () {
                    Navigator.of(context).pop();
                    context.push('/devices?homeId=$_homeId');
                  },
                ),
                _QuickAction(
                  icon: Icons.show_chart,
                  label: 'Energy',
                  onTap: () {
                    Navigator.of(context).pop();
                    context.push('/node/$nodeId/energy');
                  },
                ),
                _QuickAction(
                  icon: Icons.memory,
                  label: 'Telemetry',
                  onTap: () {
                    Navigator.of(context).pop();
                    context.push('/node/$nodeId/telemetry');
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Activate a scene and report the real outcome from the backend
  /// ({acceptedCount, failed[]}) instead of a fake "Activating scene..." toast.
  Future<void> _activateScene(String sceneId, List<Scene> scenes) async {
    final name = scenes
        .where((s) => s.id == sceneId)
        .map((s) => s.name)
        .firstOrNull;
    try {
      final result = await ref.read(sceneServiceProvider).activate(sceneId);
      if (!mounted) return;

      final message = result.isFullSuccess
          ? '${name ?? 'Scene'} on · ${result.acceptedCount} device(s) updated'
          : '${name ?? 'Scene'} partly applied · ${result.acceptedCount} ok, '
              '${result.failed.length} failed: ${result.failed.join(', ')}';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor:
              result.isFullSuccess ? V3Colors.surface2 : V3Colors.surface2,
        ),
      );

      // Refresh device state so the grid reflects the new values.
      ref.invalidate(homeNodesProvider(_homeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not activate ${name ?? 'scene'}: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: V3Colors.errorAlt,
        ),
      );
    }
  }

  Widget _buildLoading() {
    return ListView(
      padding: const EdgeInsets.all(V3Spacing.md),
      children: const [
        SHESkeleton(height: 120),
        SizedBox(height: V3Spacing.md),
        SHESkeleton(height: 84),
        SizedBox(height: V3Spacing.md),
        Row(
          children: [
            Expanded(child: SHESkeleton(height: 130)),
            SizedBox(width: 12),
            Expanded(child: SHESkeleton(height: 130)),
          ],
        ),
      ],
    );
  }

  Widget _buildError(Object error) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SHEEmptyState(
          icon: Icons.wifi_off,
          tone: V3Colors.warningAlt,
          title: 'Cannot reach SHE cloud',
          body: 'Check your internet connection and try again.',
          actionLabel: 'Retry',
          onAction: () => ref.invalidate(homeNodesProvider(_homeId)),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Header — avatar, greeting, home name, bell.
// -----------------------------------------------------------------------------
class _Header extends StatelessWidget {
  const _Header({
    required this.online,
    required this.total,
    required this.onNotifications,
    required this.onProfile,
    this.hasUnread = false,
  });

  final int online;
  final int total;
  final VoidCallback onNotifications;
  final VoidCallback onProfile;

  /// Drives the bell's dot. Was hardcoded false before the Notifications screen
  /// existed; now fed by `unreadNotificationCountProvider`.
  final bool hasUnread;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : 'Good evening';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          V3Spacing.md, V3Spacing.md, V3Spacing.md, 12),
      child: Row(
        children: [
          const SHEAvatar(name: 'SHE', size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: V3Colors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    const Icon(Icons.home_outlined,
                        size: 13, color: V3Colors.text2),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'My Home · Addis Ababa',
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
              ],
            ),
          ),
          _BellButton(onTap: onNotifications, hasUnread: hasUnread),
          const SizedBox(width: V3Spacing.sm),
          GestureDetector(
            onTap: onProfile,
            child: const SHEAvatar(name: 'S', size: 34),
          ),
        ],
      ),
    );
  }
}

class _BellButton extends StatelessWidget {
  const _BellButton({required this.onTap, required this.hasUnread});

  final VoidCallback onTap;
  final bool hasUnread;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SHEIconButton(
          icon: Icons.notifications_none,
          semanticLabel: 'Notifications',
          onPressed: onTap,
        ),
        if (hasUnread)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: V3Colors.errorAlt,
                shape: BoxShape.circle,
                border: Border.all(color: V3Colors.background, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Hero status card — gradient panel with online/offline and live socket state.
// -----------------------------------------------------------------------------
class _HeroStatus extends StatelessWidget {
  const _HeroStatus({
    required this.online,
    required this.offline,
    required this.live,
  });

  final int online;
  final int offline;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
      child: Container(
        padding: const EdgeInsets.all(V3Spacing.md),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              V3Colors.heroTop,
              V3Colors.heroMid,
              V3Colors.heroBottom,
            ],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: V3Colors.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SHEOverline('Home status'),
                      SizedBox(height: 3),
                      Text(
                        'My Home',
                        style: TextStyle(
                          color: V3Colors.ink,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: V3Colors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: live
                              ? V3Colors.successAlt
                              : V3Colors.warningAlt,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        live ? 'Live' : 'Offline',
                        style: const TextStyle(
                          color: V3Colors.primary,
                          fontSize: V3Typography.chip,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _Stat(
                  label: 'Online',
                  value: '$online',
                  tint: V3Colors.successAlt,
                ),
                const SizedBox(width: 22),
                _Stat(
                  label: 'Offline',
                  value: '$offline',
                  tint: offline > 0 ? V3Colors.warningAlt : V3Colors.dim,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Dashboard card: the home's temperature + humidity (HVAC). This replaces the
/// old per-board tile. Shows "—" placeholders until a climate sensor reports.
class _ClimateCard extends ConsumerWidget {
  const _ClimateCard({required this.homeId});

  final String homeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final climate = ref.watch(homeClimateProvider(homeId)).valueOrNull;
    final temp = climate?.temp;
    final humidity = climate?.humidity;
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.thermostat, size: 18, color: V3Colors.primary),
              const SizedBox(width: 8),
              const Text('Climate',
                  style: TextStyle(
                      color: V3Colors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: V3Spacing.md),
          Row(
            children: [
              _ClimateGauge(
                icon: Icons.thermostat,
                label: 'Temperature',
                value: temp == null ? '—' : '${temp.toStringAsFixed(1)}°C',
                fraction: temp == null
                    ? null
                    : (temp / 40).clamp(0.0, 1.0).toDouble(),
                tint: V3Colors.warningAlt,
              ),
              const SizedBox(width: V3Spacing.sm),
              _ClimateGauge(
                icon: Icons.water_drop_outlined,
                label: 'Humidity',
                value:
                    humidity == null ? '—' : '${humidity.toStringAsFixed(0)}%',
                fraction: humidity == null
                    ? null
                    : (humidity / 100).clamp(0.0, 1.0).toDouble(),
                tint: V3Colors.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A compact HVAC ring gauge: a value + label beside a ring that fills with the
/// reading. Placeholder-safe (null → empty ring).
class _ClimateGauge extends StatelessWidget {
  const _ClimateGauge({
    required this.icon,
    required this.label,
    required this.value,
    required this.fraction,
    required this.tint,
  });

  final IconData icon;
  final String label;
  final String value;
  final double? fraction;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: V3Spacing.sm, vertical: V3Spacing.sm),
        decoration: BoxDecoration(
          color: V3Colors.surface.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(V3Radius.lg),
          border: Border.all(color: V3Colors.border),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              height: 42,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(
                      value: fraction ?? 0,
                      strokeWidth: 3.5,
                      backgroundColor: V3Colors.border,
                      valueColor: AlwaysStoppedAnimation<Color>(tint),
                    ),
                  ),
                  Icon(icon, size: 18, color: tint),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: V3Colors.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: V3Colors.text2,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.tint});

  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(
          value,
          style: const TextStyle(
            color: V3Colors.ink,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            color: V3Colors.text2,
            fontSize: V3Typography.meta,
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Scenes row — compact tiles + a dashed "create" affordance.
// -----------------------------------------------------------------------------
class _ScenesRow extends StatelessWidget {
  const _ScenesRow({
    required this.scenes,
    required this.onActivate,
    required this.onManage,
  });

  final List<Map<String, dynamic>> scenes;
  final ValueChanged<String> onActivate;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
        children: [
          for (final s in scenes)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _SceneTile(
                name: s['name']?.toString() ?? 'Scene',
                icon: s['icon']?.toString() ?? 'scene',
                onTap: () => onActivate(s['id'].toString()),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _CreateSceneTile(onTap: onManage),
          ),
        ],
      ),
    );
  }
}

class _SceneTile extends StatelessWidget {
  const _SceneTile({
    required this.name,
    required this.icon,
    required this.onTap,
  });

  final String name;
  final String icon;
  final VoidCallback onTap;

  static IconData _iconFor(String key) {
    final k = key.toLowerCase();
    if (k.contains('sunrise') || k.contains('morning')) return Icons.wb_twilight;
    if (k.contains('door') || k.contains('away') || k.contains('leaving')) {
      return Icons.door_front_door_outlined;
    }
    if (k.contains('movie') || k.contains('tv')) return Icons.movie_outlined;
    if (k.contains('moon') || k.contains('night') || k.contains('sleep')) {
      return Icons.dark_mode_outlined;
    }
    return Icons.auto_awesome;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 86,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.lg),
          border: Border.all(color: V3Colors.border, width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: V3Colors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(V3Radius.md),
              ),
              child: Icon(_iconFor(icon),
                  size: 18, color: V3Colors.primary),
            ),
            const SizedBox(height: V3Spacing.sm),
            Text(
              name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: V3Colors.text2,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateSceneTile extends StatelessWidget {
  const _CreateSceneTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(V3Radius.lg),
          border: Border.all(
            color: V3Colors.borderStrong,
            width: 1,
            style: BorderStyle.solid,
          ),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 20, color: V3Colors.dim),
            SizedBox(height: 6),
            Text(
              'Create',
              style: TextStyle(
                color: V3Colors.dim,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Bento device card — node-level. Reads the node's first device for state.
// -----------------------------------------------------------------------------
class _BentoCard extends ConsumerWidget {
  const _BentoCard({
    required this.node,
    required this.onOpen,
    required this.onLongPress,
  });

  final Map<String, dynamic> node;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeId = node['id']?.toString() ?? '';
    final isOnline = node['is_online'] == true;
    final name = node['name']?.toString() ??
        node['node_id']?.toString() ??
        'Device';
    final sku = node['sku']?.toString() ?? '';

    // Pull the node's devices so the tile can show a real switch + kind icon.
    final devicesAsync = ref.watch(_nodeDevicesProvider(nodeId));
    final first = devicesAsync.valueOrNull?.firstOrNull;

    final deviceType = first?['device_type']?.toString() ?? '';
    // The device NAME disambiguates relay channels, which all share one type.
    final deviceName = first?['display_name']?.toString() ??
        first?['device_name']?.toString() ??
        '';
    final kind = _kindFromType(deviceType, name: deviceName);
    final params = (first?['params'] as List<dynamic>? ?? const []);
    final power = params.cast<Map<String, dynamic>?>().firstWhere(
          (p) => p?['param_name'] == 'Power',
          orElse: () => null,
        );
    final isOn = power?['last_value'] == true;
    final deviceId = first?['id']?.toString();

    return GestureDetector(
      onLongPress: onLongPress,
      child: SHECard(
        onTap: onOpen,
        raised: isOn && isOnline,
        glow: isOn && isOnline,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeviceIcon(
                  kind: kind,
                  on: isOn && isOnline,
                  size: 40,
                ),
                const Spacer(),
                if (deviceId != null)
                  SHEToggle(
                    value: isOn,
                    enabled: isOnline,
                    onChanged: (v) => _write(ref, nodeId, deviceId, v),
                  )
                else
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 6, right: 4),
                    decoration: BoxDecoration(
                      color: isOnline
                          ? V3Colors.successAlt
                          : V3Colors.errorAlt,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const Spacer(),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: V3Colors.ink,
                fontSize: V3Typography.cardTitle,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(
                  child: Text(
                    sku.isNotEmpty ? sku : (isOnline ? 'Online' : 'Offline'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: !isOnline
                          ? V3Colors.warningAlt
                          : (isOn ? V3Colors.primary : V3Colors.dim),
                      fontSize: V3Typography.meta,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _write(
      WidgetRef ref, String nodeId, String deviceId, bool value) async {
    try {
      await ref
          .read(nodeServiceProvider)
          .writeParams(nodeId, deviceId, {'Power': value});
      // Invalidate the SHARED provider so the Devices tab and this grid agree.
      ref.invalidate(homeNodesProvider);
      ref.invalidate(_nodeDevicesProvider(nodeId));
    } catch (_) {
      // The toggle simply reverts on the next refetch; no silent state change.
    }
  }
}

/// Devices of a single node, cached per node id.
final _nodeDevicesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, nodeId) {
  if (nodeId.isEmpty) return Future.value(const []);
  return ref.read(nodeServiceProvider).listDevices(nodeId);
});

/// Firmware `esp.device.*` → prototype kind vocabulary.
///
/// Every relay channel reports `esp.device.switch` regardless of whether it
/// drives a light or a socket, so [name] is consulted as a tie-breaker. Keep
/// this in step with `_kindFromDeviceType` in features/devices/devices_screen.dart
/// — the two screens must agree or the same device changes icon between them.
String _kindFromType(String type, {String name = ''}) {
  if (type.contains('lightbulb')) return 'light';
  if (type.contains('fan')) return 'appliance';
  if (type.contains('temp_sensor')) return 'climate';
  if (type.contains('energy_meter')) return 'meter';

  final n = name.toLowerCase();
  if (n.contains('socket') || n.contains('outlet') || n.contains('plug')) {
    return 'outlet';
  }
  if (n.contains('light') || n.contains('lamp')) return 'light';
  if (n.contains('fan')) return 'appliance';
  if (n.contains('gate') || n.contains('door')) return 'gate';
  if (n.contains('pump') || n.contains('irrigation') || n.contains('water')) {
    return 'irrigation';
  }
  if (n.contains('camera')) return 'camera';
  if (n.contains('tv')) return 'tv';
  if (n.contains('meter')) return 'meter';

  if (type.contains('switch') || type.contains('relay')) return 'outlet';
  if (type.contains('sensor')) return 'sensor';
  return 'generic';
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: V3Colors.fill,
                borderRadius: BorderRadius.circular(V3Radius.lg),
              ),
              child: Icon(icon, size: 22, color: V3Colors.text2),
            ),
            const SizedBox(height: V3Spacing.sm),
            Text(
              label,
              style: const TextStyle(
                color: V3Colors.text2,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Energy mini card — links to the home energy tab. Reuses the existing
// EnergySummaryCard's provider so the Phase 4 note stays honest.
// -----------------------------------------------------------------------------
class _EnergyMiniCard extends ConsumerWidget {
  const _EnergyMiniCard({required this.homeId});

  final String homeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeEnergySummaryProvider(homeId));

    return SHECard(
      onTap: () => context.push('/energy?homeId=$homeId'),
      padding: const EdgeInsets.all(V3Spacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SHEOverline('Energy'),
                const SizedBox(height: 5),
                async.when(
                  loading: () => const SizedBox(
                    height: 20,
                    child: SHESkeleton(width: 90, height: 18),
                  ),
                  error: (_, __) => const Text(
                    'Unavailable',
                    style: TextStyle(
                      color: V3Colors.dim,
                      fontSize: V3Typography.body,
                    ),
                  ),
                  data: (s) => Text(
                    s.isReal ? 'Live metrics' : 'Phase 4',
                    style: const TextStyle(
                      color: V3Colors.ink,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Consumption & cost',
                  style: TextStyle(
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
    );
  }
}

// -----------------------------------------------------------------------------
// Weather card — current conditions for Addis Ababa. Placeholder-safe: shows
// "—" while loading and when the source is unreachable.
// -----------------------------------------------------------------------------
class _WeatherCard extends ConsumerWidget {
  const _WeatherCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_weatherProvider);
    final w = async.valueOrNull;
    final (icon, label) = _weatherVisual(w?.code ?? 3);

    final temp = w?.tempC;
    final headline = temp == null ? '—' : '${temp.toStringAsFixed(0)}°C · $label';
    final humidity = w?.humidity;

    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: V3Colors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
            child: Icon(icon, size: 22, color: V3Colors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: const [
                    Icon(Icons.location_on_outlined,
                        size: 12, color: V3Colors.text2),
                    SizedBox(width: 3),
                    Text('Addis Ababa',
                        style: TextStyle(
                            color: V3Colors.text2, fontSize: V3Typography.meta)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: V3Colors.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (humidity != null)
            Row(
              children: [
                const Icon(Icons.water_drop_outlined,
                    size: 14, color: V3Colors.text2),
                const SizedBox(width: 4),
                Text(
                  '${humidity.toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: V3Colors.text2, fontSize: V3Typography.meta),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

