// =============================================================================
// SHE V3 — Devices screen (prototype `devices.tsx` · Devices list, §8)
// =============================================================================
// Filter + search over a flat device list, with a per-row toggle. Introduced by
// the SHE-V3 UI/UX redesign as the "Devices" tab.
//
// It reuses the SAME data the dashboard already loads — `homeNodesProvider`
// (dashboard_screen.dart) plus `nodeServiceProvider.listDevices()` — so there is
// no second source of truth for device state and a toggle here updates the grid
// there (both invalidate `homeNodesProvider`).
//
// Kept intentionally free of new API calls: everything goes through NodeService,
// which is already exercised by the dashboard and the device-detail screen.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/ws_client.dart' show livePowerProvider;
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../../l10n/app_localizations.dart';
import '../dashboard/dashboard_screen.dart' show homeNodesProvider;
import '../device_detail/device_detail_screen.dart'
    show nodeDeviceParamsProvider;
import '../device_detail/node_service.dart';
import '../voice/voice_hold_button.dart';

/// A device flattened out of its node, so the list can render one row per
/// physical device rather than one card per board.
class _DeviceRow {
  final String nodeId;
  final String deviceId;
  final String name;
  final String kind;
  final bool isOnline;
  final bool isOn;

  /// The server's raw device map. Kept so the row can be handed to anything that
  /// needs the original payload rather than the flattened fields.
  final Map<String, dynamic> raw;

  const _DeviceRow({
    required this.nodeId,
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.isOnline,
    required this.isOn,
    required this.raw,
  });
}

// NOTE (2026-10-06): the app-scoped optimistic power override that used to live
// here was REMOVED. The board's feedback circuit senses the light line, so the
// switch must mirror the board's `reported_value` and must never show ON before
// the bulb is actually on. See _effectiveOn / _toggle below.

/// Resolves every node's devices into a flat list.
///
/// Depends on [homeNodesProvider] so it re-runs whenever the dashboard refetches
/// (which is what makes a toggle on either screen show up on the other).
final _homeDevicesFlatProvider =
    FutureProvider.family<List<_DeviceRow>, String>((ref, homeId) async {
  final nodes = await ref.watch(homeNodesProvider(homeId).future);
  final service = ref.read(nodeServiceProvider);
  final out = <_DeviceRow>[];

  for (final node in nodes) {
    final nodeId = node['id']?.toString();
    if (nodeId == null) continue;
    final isOnline = node['is_online'] == true;

    List<Map<String, dynamic>> devices;
    try {
      devices = await service.listDevices(nodeId);
    } catch (_) {
      // A single unreachable board must not blank the whole list.
      continue;
    }

    for (final d in devices) {
      final deviceId = d['id']?.toString();
      if (deviceId == null) continue;
      final params = (d['params'] as List<dynamic>? ?? const []);
      final power = params.cast<Map<String, dynamic>?>().firstWhere(
            (p) => p?['param_name'] == 'Power',
            orElse: () => null,
          );

      // 🔴 `kind` used to be the RAW `device_type`. The firmware reports every
      // relay channel as `esp.device.switch` (device_profiles.c,
      // build_relay_device), so `kind` was literally "esp.device.switch" for all
      // 24 channels and _matchesFilter() compared it against 'light' / 'outlet' —
      // never true. Every chip except "All" matched nothing, which is why there
      // were no lights under Lights and no sockets under Appliances.
      // _kindFromDeviceType() already existed to solve exactly this; it just was
      // never called.
      //
      // The role word lives in the NAME, so both names are offered to the
      // classifier: `device_name` is the firmware's stable role name
      // ("Light 1".."Light 16" / "Socket 1".."Socket 8"), and `display_name` is a
      // user rename. Matching either means renaming a device to "bedroom light"
      // still lands it under Lights, and a board that reports a bare "relay_7"
      // still resolves.
      final displayName = d['display_name']?.toString() ??
          d['device_name']?.toString() ??
          'Device';
      final roleName = [
        d['device_name']?.toString() ?? '',
        d['display_name']?.toString() ?? '',
      ].where((s) => s.isNotEmpty).join(' ');

      out.add(_DeviceRow(
        nodeId: nodeId,
        deviceId: deviceId,
        name: displayName,
        kind: _kindFromDeviceType(
          d['device_type']?.toString() ?? '',
          name: roleName,
        ),
        isOnline: isOnline,
        // V38: the DEVICE-reported value is the truth. `last_value` is also
        // written by our own commands, so it could show "on" with no feedback.
        isOn: power?['reported_value'] == true,
        raw: d,
      ));
    }
  }
  return out;
});

/// Maps a device onto the prototype's kind vocabulary so icons and tints differ.
///
/// The firmware registers EVERY relay channel as `esp.device.switch` — on the
/// R24 board that is 16 lights and 8 sockets all reporting the identical type
/// (see `firmware/v3/main/device_profiles.c`, `build_relay_device`). Type alone
/// therefore cannot tell a light from a socket, and every row rendered the same
/// icon.
///
/// The channel's physical role lives in its NAME: the firmware ships
/// `relay_names_r24` as "Light 1".."Light 16" / "Socket 1".."Socket 8".
/// So: prefer the concrete `esp.device.*` type when it is specific, and fall
/// back to keyword-matching the display name for the generic relay type.
String _kindFromDeviceType(String type, {String name = ''}) {
  // ---- Specific firmware types: unambiguous, trust them first ----
  if (type.contains('lightbulb')) return 'light';
  if (type.contains('fan')) return 'appliance';
  if (type.contains('temp_sensor')) return 'climate';
  if (type.contains('energy_meter')) return 'meter';

  // ---- Relay channels: type is generic, so read the name ----
  // Checked in priority order. Word-boundary-ish matching on a lowercased name
  // so "Socket 1" and "Power Socket" both resolve to an outlet.
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

  // ---- Generic switch / relay / unknown ----
  if (type.contains('switch') || type.contains('relay')) return 'outlet';
  if (type.contains('sensor')) return 'sensor';
  return 'generic';
}

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key, this.homeId});

  /// Resolved by the caller when known; when null/empty this screen discovers
  /// the user's first home itself (same pattern the dashboard uses).
  final String? homeId;

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';

  late String _homeId;
  final _searchController = TextEditingController();
  String _query = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    final initial = widget.homeId;
    _homeId = (initial != null && initial.isNotEmpty) ? initial : _defaultHomeId;
    if (initial == null || initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _resolveHome() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (homes.isNotEmpty && mounted) {
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) setState(() => _homeId = id);
      }
    } catch (_) {
      // Keep the seeded default; the provider degrades to an empty list.
    }
  }

  bool _matchesFilter(_DeviceRow d) => switch (_filter) {
        'lights' => d.kind == 'light',
        'appliances' => d.kind == 'outlet' || d.kind == 'appliance',
        'security' => d.kind == 'camera' || d.kind == 'gate',
        'climate' => d.kind == 'climate' || d.kind == 'irrigation',
        'other' =>
          d.kind == 'sensor' || d.kind == 'meter' || d.kind == 'tv' || d.kind == 'generic',
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final devicesAsync = ref.watch(_homeDevicesFlatProvider(_homeId));

    return Scaffold(
      backgroundColor: V3Colors.background,
      // Push-to-talk voice control, matching the R24 detail page and the
      // dashboard. The Devices tab was the one screen of the three without it,
      // which read as "the mic is missing" after the new UI/UX landed.
      floatingActionButton: const VoiceHoldButton(),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SHEAppBar(
              title: l?.device ?? 'Devices',
              subtitle: devicesAsync.maybeWhen(
                data: (list) {
                  final online = list.where((d) => d.isOnline).length;
                  return '$online ${l?.online ?? 'online'} · '
                      '${list.length - online} ${l?.offline ?? 'offline'}';
                },
                orElse: () => null,
              ),
              large: true,
              trailing: SHEIconButton(
                icon: Icons.add,
                semanticLabel: l?.addDevice ?? 'Add device',
                onPressed: () => context.push('/provisioning'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
              child: SHESearchField(
                controller: _searchController,
                hint: l?.device ?? 'Search devices',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
                children: [
                  for (final f in const [
                    ('all', 'All'),
                    ('lights', 'Lights'),
                    ('appliances', 'Appliances'),
                    ('security', 'Security'),
                    ('climate', 'Climate'),
                    ('other', 'Other'),
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
              child: RefreshIndicator(
                color: V3Colors.primary,
                backgroundColor: V3Colors.surface,
                onRefresh: () => ref.refresh(_homeDevicesFlatProvider(_homeId).future),
                child: devicesAsync.when(
                  // A toggle invalidates this provider, which is a RELOAD — the
                  // default would swap the whole list for skeletons for the
                  // duration of the refetch and read as "the switch is slow".
                  // Keep the previous rows on screen instead.
                  skipLoadingOnReload: true,
                  loading: () => _buildLoading(),
                  error: (e, _) => _buildError(e),
                  data: (all) {
                    final list = all.where((d) {
                      if (!_matchesFilter(d)) return false;
                      if (_query.isEmpty) return true;
                      final q = _query.toLowerCase();
                      return d.name.toLowerCase().contains(q);
                    }).toList();

                    if (list.isEmpty) {
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SHEEmptyState(
                            icon: _query.isNotEmpty
                                ? Icons.search_off
                                : Icons.devices_other,
                            tone: V3Colors.dim,
                            title: _query.isNotEmpty
                                ? 'No matching devices'
                                : 'No devices found',
                            body: _query.isNotEmpty
                                ? 'Try a different name or clear the filters.'
                                : 'Add your first SHE device to get started.',
                            actionLabel: _query.isEmpty ? 'Add Device' : null,
                            onAction: _query.isEmpty
                                ? () => context.push('/provisioning')
                                : null,
                          ),
                        ],
                      );
                    }

                    // Live Power per device, read from nodeDeviceParamsProvider
                    // — the provider `ws_client` invalidates on every
                    // `node.state` event, and the very same one the group panel
                    // and the R24 detail page use. THIS is what makes the switch
                    // follow the board instead of only the last tap.
                    //
                    // Watched up here, not inside itemBuilder, because
                    // `ref.watch` is unsafe in a builder callback.
                    final liveOn = <String, bool>{};
                    for (final d in all) {
                      ref
                          .watch(nodeDeviceParamsProvider(
                              '${d.nodeId}|${d.deviceId}'))
                          .whenData((params) {
                        final p = params
                            .cast<Map<String, dynamic>?>()
                            .firstWhere(
                              (x) => x?['param_name'] == 'Power',
                              orElse: () => null,
                            );
                        if (p != null) {
                          // V38 — the switch follows what the DEVICE reported,
                          // not last_value (which our own commands also write).
                          liveOn[d.deviceId] = p['reported_value'] == true;
                        }
                      });
                    }

                    return ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                          V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.xxl),
                      itemCount: list.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final row = list[i];
                        return _DeviceTile(
                          device: row,
                          // Pass the optimistic value, not the raw server one, so
                          // the switch reflects the tap immediately.
                          isOn: _effectiveOn(row, liveOn),
                          onToggle: () =>
                              _toggle(row, _effectiveOn(row, liveOn)),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(_DeviceRow d, bool current) async {
    if (!d.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${d.name} is offline — the command was not sent.'),
          backgroundColor: V3Colors.surface2,
        ),
      );
      return;
    }

    // No optimistic flip. The board's feedback circuit senses the light line,
    // so the switch must only move once the board reports the bulb actually
    // changed — never before. Send the command, then let the refetch catch up.
    final target = !current;

    try {
      // Same path the dashboard's bento cards use, so group/state handling and
      // the server-side last_value update are identical.
      // writeParams takes a params MAP (NodeService:49), keyed by param name.
      await ref
          .read(nodeServiceProvider)
          .writeParams(d.nodeId, d.deviceId, {'Power': target});

      // Invalidate all three: the flat list caches the resolved devices,
      // homeNodesProvider is what the dashboard reads, and the per-device params
      // provider is what THIS switch now reads (and what the group panel reads).
      // Invalidating only the first two left the switch stale.
      ref.invalidate(_homeDevicesFlatProvider(_homeId));
      ref.invalidate(homeNodesProvider(_homeId));
      ref.invalidate(
          nodeDeviceParamsProvider('${d.nodeId}|${d.deviceId}'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not reach ${d.name}: $e'),
          backgroundColor: V3Colors.errorAlt,
        ),
      );
    }
  }

  /// What the switch displays.
  ///
  /// Priority: a still-fresh optimistic tap, then the board's **reported** Power,
  /// then the cached value from the flat list.
  ///
  /// [liveOn] comes from `nodeDeviceParamsProvider` — the same provider the R24
  /// detail page and the group panel read, and the one `ws_client` invalidates on
  /// every `node.state` event. That is what makes this switch follow the board
  /// (a wall switch, AC feedback, a scene, master control) instead of only the
  /// last thing the app asked for.
  bool _effectiveOn(_DeviceRow d, Map<String, bool> liveOn) {
    // ALWAYS the board's reported Power — deliberately NO optimistic value.
    //
    // Prefer the value straight off the WS `node.state` payload
    // ([livePowerProvider]): it lands the instant the board publishes, so a
    // wall-switch change shows up without waiting for any REST refetch. Fall
    // back to the REST-fetched `reported_value`, then OFF — so the switch still
    // never shows ON unless the board reported it.
    final ws = ref.watch(livePowerProvider)[d.deviceId];
    if (ws != null) return ws;
    return liveOn[d.deviceId] ?? false;
  }

  Widget _buildLoading() {
    return ListView.separated(
      padding: const EdgeInsets.all(V3Spacing.md),
      itemCount: 6,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => const SHESkeleton(height: 68),
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
          onAction: () => ref.invalidate(_homeDevicesFlatProvider(_homeId)),
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.isOn,
    required this.onToggle,
  });

  final _DeviceRow device;

  /// Effective power state — the optimistic value while a write is in flight,
  /// otherwise the server's. Never read `device.isOn` directly here.
  final bool isOn;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // Pass the display name too: relay channels all share `esp.device.switch`,
    // so the name is what distinguishes a light from a socket (see the mapper).
    final kind = _kindFromDeviceType(device.kind, name: device.name);
    return SHECard(
      // Toggle-only row: the card is deliberately NOT tappable, so the switch
      // owns the whole gesture and flips instantly (no gesture-arena delay from
      // a competing card onTap), and there is no second "device page" to open.
      raised: isOn && device.isOnline,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          DeviceIcon(
            kind: kind,
            on: isOn && device.isOnline,
            size: 44,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    SHEStatusBadge(online: device.isOnline),
                    if (isOn && device.isOnline) ...[
                      const SizedBox(width: 6),
                      const Text(
                        'On',
                        style: TextStyle(
                          color: V3Colors.primary,
                          fontSize: V3Typography.meta,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: V3Spacing.sm),
          SHEToggle(
            value: isOn,
            enabled: device.isOnline,
            onChanged: (_) => onToggle(),
          ),
        ],
      ),
    );
  }
}
