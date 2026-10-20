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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/local/local_control_service.dart';
import '../../core/network/active_home.dart';
import '../../core/offline/device_snapshot.dart';
import '../../core/network/ws_client.dart'
    show livePowerProvider, wsConnectedProvider;
import '../../core/offline/command_queue.dart';
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

  /// Snapshot for the offline cache (see [_homeDevicesFlatProvider]). The raw
  /// server map is kept so a cached row behaves exactly like a fresh one — the
  /// toggle needs `raw['device_name']` to address the board over local control.
  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'deviceId': deviceId,
        'name': name,
        'kind': kind,
        'isOnline': isOnline,
        'isOn': isOn,
        'raw': raw,
      };

  factory _DeviceRow.fromJson(Map<String, dynamic> j) => _DeviceRow(
        nodeId: j['nodeId']?.toString() ?? '',
        deviceId: j['deviceId']?.toString() ?? '',
        name: j['name']?.toString() ?? 'Device',
        kind: j['kind']?.toString() ?? 'light',
        isOnline: j['isOnline'] == true,
        isOn: j['isOn'] == true,
        raw: (j['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
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
  // ---- Offline snapshot cache ----------------------------------------------
  // The Devices tab is the ONLY place to reach an individual device, so it has
  // to survive an outage: with no rows there is nothing to tap, which makes the
  // local-control path unreachable exactly when it is needed. Without this an
  // offline cold start showed "Cannot reach SHE cloud" and the banner's
  // "Showing cached data" promise was simply untrue.
  //
  // The keys live in core/offline/device_snapshot.dart because the automation
  // wizard's device picker reads the same snapshot.
  List<_DeviceRow>? readCache() {
    final cached = readDeviceSnapshot(homeId);
    if (cached == null) return null;
    final rows = <_DeviceRow>[];
    for (final j in cached) {
      rows.add(_DeviceRow.fromJson(j));
    }
    return rows.isEmpty ? null : rows;
  }

  List<Map<String, dynamic>> nodes;
  try {
    nodes = await ref.watch(homeNodesProvider(homeId).future);
  } catch (_) {
    final rows = readCache();
    if (rows != null) return rows;
    rethrow; // nothing cached: the error state is the honest answer
  }

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

      // Internal firmware services (the OTA service channel) are not user-facing
      // devices. The detail screen already hides them (`!is_service`), but the
      // flat list was the last place still rendering them as a toggleable "OTA"
      // row — which is also what put "OTA · On" into the command queue.
      if (d['is_service'] == true) continue;

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

  // An EMPTY result while the cloud is unreachable is not the truth. The usual
  // cause is an unresolved home id, whose home legitimately contains nothing —
  // and "No devices found" is a dead end: no rows to tap, so no local control,
  // which is exactly what the snapshot exists to prevent.
  if (out.isEmpty && !ref.read(wsConnectedProvider)) {
    final rows = readCache();
    if (rows != null) return rows;
  }

  // Persist the snapshot. writeDeviceSnapshot ignores an empty list, so an
  // unresolved home id (or a genuinely empty home) can never wipe the last good
  // one — and the automation wizard's device picker reads the same snapshot.
  await writeDeviceSnapshot(homeId, [for (final r in out) r.toJson()]);
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

  /// While the cloud link is DOWN, polls the board's `/she/info` so a PHYSICAL
  /// wall-switch flip shows up here — offline there is no push channel.
  Timer? _localPoll;

  @override
  void initState() {
    super.initState();
    final initial = widget.homeId;
    _homeId = (initial != null && initial.isNotEmpty) ? initial : _defaultHomeId;
    if (initial == null || initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncLocalPoll());
  }

  @override
  void dispose() {
    _localPoll?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _resolveHome() async {
    // Picks the home that actually HAS nodes. `homes.first` was arbitrary — this
    // tenant has 32 homes named "My Home", and landing on an empty one showed
    // "No devices found" with the real home untouched. See
    // core/network/active_home.dart.
    final id = await resolveActiveHomeId(ref);
    if (id != null && mounted && id != _homeId) {
      setState(() => _homeId = id);
    }
  }

  /// Run the offline board poll ONLY while the cloud link is down.
  void _syncLocalPoll() {
    if (!mounted) return;
    if (ref.read(wsConnectedProvider)) {
      _localPoll?.cancel();
      _localPoll = null;
      return;
    }
    _localPoll ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_pollBoard()),
    );
    unawaited(_pollBoard()); // first read immediately
  }

  /// Push every device's board-REPORTED Power into [livePowerProvider].
  ///
  /// This is what surfaces a PHYSICAL wall-switch flip while offline: without it
  /// the app only learns state from its OWN command feedback. Writes are skipped
  /// when unchanged, so the list does not churn on every poll.
  Future<void> _pollBoard() async {
    if (!mounted || ref.read(wsConnectedProvider)) return;
    final svc = ref.read(localControlServiceProvider);
    if (!svc.isConfigured) return;

    final byName = await svc.readAllPower();
    if (byName == null || byName.isEmpty || !mounted) return;

    final rows = ref.read(_homeDevicesFlatProvider(_homeId)).valueOrNull;
    if (rows == null) return;

    final live = ref.read(livePowerProvider);
    final notifier = ref.read(livePowerProvider.notifier);
    for (final r in rows) {
      final name = r.raw['device_name']?.toString();
      if (name == null || name.isEmpty) continue;
      final reported = byName[name];
      if (reported == null) continue;
      if (live[r.deviceId] != reported) notifier.set(r.deviceId, reported);
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

    // A provider failure is CACHED, so it does not clear itself when the link
    // comes back — the tab would stay on "Cannot reach SHE cloud" until the app
    // was restarted. Clear it the moment the live link returns.
    ref.listen(wsConnectedProvider, (prev, next) {
      if (next && prev != true) _retry();
      // Start/stop the offline board poll with the link state.
      _syncLocalPoll();
    });

    final devicesAsync = ref.watch(_homeDevicesFlatProvider(_homeId));

    // An EMPTY list while still on the placeholder home id is not the truth — it
    // means we picked the WRONG home (see core/network/active_home.dart). Re-resolve
    // so a launch that landed on an empty husk heals itself instead of showing
    // "No devices found" forever.
    if (_homeId == _defaultHomeId) {
      final rows = devicesAsync.valueOrNull;
      if (rows != null && rows.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _resolveHome();
        });
      }
    }

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

                    // The instant value straight off the WS `node.state` payload —
                    // and, OFFLINE, the value local control read back from the
                    // board's feedback circuit. Watched UP HERE with the others:
                    // this used to be watched inside `_effectiveOn`, which is
                    // called from the itemBuilder, where `ref.watch` does not
                    // register a dependency. Online that went unnoticed because the
                    // WS event also invalidates the providers, so the list rebuilt
                    // anyway — but offline the invalidation is deliberately skipped
                    // (it would blank the list), so the switch never moved at all.
                    final wsOn = ref.watch(livePowerProvider);

                    // Design sheet #23 — devices with a command waiting to send.
                    // Watched up here (like liveOn) because ref.watch is unsafe
                    // inside an itemBuilder callback. The map holds the QUEUED
                    // Power so the switch can show the user's intent while the
                    // command waits, instead of looking dead.
                    final queuedOn = <String, bool>{};
                    for (final c in ref.watch(commandQueueProvider)) {
                      final p = c.params['Power'];
                      if (p is bool) queuedOn[c.deviceId] = p;
                    }

                    // Phones keep the single-column list; tablets/foldables get a
                    // multi-column grid of the same tiles (audit #24/#25).
                    final cols = V3Breakpoints.gridColumns(context);

                    Widget tileAt(int i) {
                      final row = list[i];
                      // A gate is not an on/off relay — it is driven by
                      // Open/Close/Stop. Route it to the dedicated Gate control
                      // screen (#8) instead of a Power toggle.
                      if (row.kind == 'gate') {
                        return _GateDeviceTile(row: row);
                      }
                      return _DeviceTile(
                        device: row,
                        // Pass the optimistic value, not the raw server one, so
                        // the switch reflects the tap immediately.
                        isOn: _effectiveOn(row, liveOn, queuedOn, wsOn),
                        queued: queuedOn.containsKey(row.deviceId),
                        onRename: () => _renameDevice(row),
                        onToggle: () =>
                            _toggle(row, _effectiveOn(row, liveOn, queuedOn, wsOn)),
                      );
                    }

                    if (cols == 1) {
                      return ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(
                            V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.xxl),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) => tileAt(i),
                      );
                    }

                    return GridView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                          V3Spacing.md, V3Spacing.sm, V3Spacing.md, V3Spacing.xxl),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 2.4,
                      ),
                      itemCount: list.length,
                      itemBuilder: (context, i) => tileAt(i),
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
      // Offline-tolerant: if the app cannot reach SHE the command is queued
      // (design sheet #23) and replayed on reconnect, instead of being lost.
      final outcome = await ref.read(commandQueueProvider.notifier).sendOrQueue(
            nodeId: d.nodeId,
            deviceId: d.deviceId,
            params: {'Power': target},
            label: '${d.name} · ${target ? 'On' : 'Off'}',
            // The board's local API addresses a device by its FIRMWARE name.
            deviceName: d.raw['device_name']?.toString(),
          );
      if (outcome == SendOutcome.queued) {
        // Offline, "queued" means local control did NOT take. Say why — a silent
        // queue makes a broken local-control setup look like a working one, and
        // there is no other way to see the reason on a release build.
        if (!ref.read(wsConnectedProvider) && mounted) {
          final fwName = d.raw['device_name']?.toString();
          final why = (fwName == null || fwName.isEmpty)
              // The board addresses devices by firmware name, so without one
              // local control can never be attempted at all.
              ? 'no device_name in the cloud payload'
              : (ref.read(localControlServiceProvider).lastError ??
                  'board unreachable');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Queued — local control failed: $why'),
            duration: const Duration(seconds: 6),
          ));
        }
        return; // the badge reflects it
      }

      // If the command went out over LOCAL CONTROL the cloud is by definition
      // unreachable, and the value is already applied in memory
      // (livePowerProvider). Refetching here could only fail — and a failed
      // refetch REPLACES this whole list with "Cannot reach SHE cloud", so a
      // perfectly successful offline toggle would blank the screen ~10 s later.
      // The board's own MQTT report refreshes the list once the link returns.
      if (!ref.read(wsConnectedProvider)) return;

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

  /// Rename a channel.
  ///
  /// Only `display_name` is written — the technical `device_name` is how the
  /// firmware addresses the relay and how local control finds it, so it must
  /// never change. The dialog accepts any text, including Ethiopic, because the
  /// column is a plain VARCHAR(100).
  Future<void> _renameDevice(_DeviceRow row) async {
    final controller = TextEditingController(
      text: row.raw['display_name']?.toString() ?? '',
    );
    final technical = row.raw['device_name']?.toString() ?? row.name;

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            // Show what the board calls it, so it is obvious which channel is
            // being renamed when the custom name is already in use.
            helperText: 'Technical name: $technical',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The dialog's field is still animating out when this returns; disposing the
    // controller immediately would trip "used after being disposed".
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null) return;

    try {
      await ref.read(nodeServiceProvider).renameDevice(
            nodeId: row.nodeId,
            deviceId: row.deviceId,
            // Empty clears the custom name and the UI falls back to the
            // technical one.
            displayName: name.isEmpty ? null : name,
          );
      ref.invalidate(_homeDevicesFlatProvider(_homeId));
      ref.invalidate(homeNodesProvider(_homeId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(name.isEmpty ? 'Name cleared' : 'Renamed to "$name"'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not rename: $e'),
          backgroundColor: V3Colors.errorAlt,
        ),
      );
    }
  }

  /// What the switch displays.
  ///
  /// Priority: a still-fresh optimistic tap, then the board's **reported** Power,  /// then the cached value from the flat list.
  ///
  /// [liveOn] comes from `nodeDeviceParamsProvider` — the same provider the R24
  /// detail page and the group panel read, and the one `ws_client` invalidates on
  /// every `node.state` event. That is what makes this switch follow the board
  /// (a wall switch, AC feedback, a scene, master control) instead of only the
  /// last thing the app asked for.
  bool _effectiveOn(_DeviceRow d, Map<String, bool> liveOn,
      Map<String, bool> queuedOn, Map<String, bool> wsOn) {
    // A QUEUED command is the user's most recent intent and the board has not
    // seen it yet — show it, so an offline tap visibly takes effect. The entry
    // is dropped when the queue flushes, at which point the board's real value
    // takes over (and by then the two agree).
    final queued = queuedOn[d.deviceId];
    if (queued != null) return queued;
    // Otherwise ALWAYS the board's reported Power — deliberately NO optimistic value.
    //
    // Prefer the value straight off the WS `node.state` payload (and, offline, the
    // value local control read back from the board's feedback circuit). It lands
    // the instant the board reports, so a wall-switch change shows up without
    // waiting for any REST refetch. Fall back to the REST-fetched
    // `reported_value`, then OFF — so the switch still never shows ON unless the
    // board reported it.
    //
    // ⚠️ [wsOn] is PASSED IN, never `ref.watch`ed here: this runs inside the
    // itemBuilder, where ref.watch registers no dependency.
    final ws = wsOn[d.deviceId];
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

  /// Clears the WHOLE failure chain, not just the visible provider.
  ///
  /// [_homeDevicesFlatProvider] awaits `homeNodesProvider`, and Riverpod CACHES a
  /// FutureProvider's failure. Invalidating only the downstream provider made the
  /// re-run re-throw that same cached error immediately, so "Retry" could never
  /// succeed — the tab stayed on "Cannot reach SHE cloud" even with the backend
  /// healthy and serving `/homes/{id}/nodes` fine.
  void _retry() {
    // The home id resolves asynchronously. If that attempt failed (e.g. the app
    // was started while offline) we are still holding the placeholder, which can
    // only ever return an empty home — so re-resolve it too.
    if (_homeId == _defaultHomeId) _resolveHome();
    ref.invalidate(homeNodesProvider(_homeId));
    ref.invalidate(_homeDevicesFlatProvider(_homeId));
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
          onAction: _retry,
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
    this.onRename,
    this.queued = false,
  });

  final _DeviceRow device;

  /// Opens the rename sheet. Null for rows that cannot be renamed.
  final VoidCallback? onRename;

  /// Effective power state — the optimistic value while a write is in flight,
  /// otherwise the server's. Never read `device.isOn` directly here.
  final bool isOn;
  final VoidCallback onToggle;

  /// Design sheet #23 — a command for this device is waiting to send.
  final bool queued;

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
                  style:  TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (queued)
                      const SHEStatusBadge(cmdState: 'queued')
                    else
                      SHEStatusBadge(online: device.isOnline),
                    if (isOn && device.isOnline && !queued) ...[
                      const SizedBox(width: 6),
                       Text(
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
          // Rename lives here rather than on the card tap: the card is
          // deliberately not tappable so the switch owns the gesture.
          if (onRename != null)
            IconButton(
              tooltip: 'Rename device',
              onPressed: onRename,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon:  Icon(Icons.edit_outlined,
                  color: V3Colors.textSecondary),
            ),
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

/// Gate devices appear in the list like any other device, but they are not
/// on/off relays — they are driven by Open / Close / Stop. Tapping opens the
/// dedicated Gate control screen (#8) instead of showing a Power toggle.
class _GateDeviceTile extends StatelessWidget {
  const _GateDeviceTile({required this.row});

  final _DeviceRow row;

  @override
  Widget build(BuildContext context) {
    final kind = _kindFromDeviceType(row.kind, name: row.name);
    return SHECard(
      onTap: () => context.push(
        '/gate?nodeId=${row.nodeId}&deviceId=${row.deviceId}'
        '&name=${Uri.encodeComponent(row.name)}&isOnline=${row.isOnline}',
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          DeviceIcon(kind: kind, on: row.isOn && row.isOnline, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:  TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    SHEStatusBadge(online: row.isOnline),
                    const SizedBox(width: 6),
                     Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: V3Colors.text2,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
