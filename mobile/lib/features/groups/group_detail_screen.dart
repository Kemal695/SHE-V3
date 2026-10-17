// =============================================================================
// SHE V3 — Group detail
// =============================================================================
// The Scenes pattern the user asked for: a premium card on the home screen opens
// a page dedicated to that one thing. Here the page is a group's member devices,
// each switchable on its own, with a master control for the whole group.
//
// Before this existed, per-device control was buried behind an inline expansion
// inside the group card on the Devices tab — discoverable only by accident. The
// detail page makes it the point of the screen.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local/local_control_service.dart';
import '../../core/media/media_service.dart';
import '../../core/network/api_error.dart';
import '../../core/network/ws_client.dart'
    show livePowerProvider, wsConnectedProvider;
import '../../core/offline/command_queue.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_icon_or_image.dart';
import '../../core/widgets/she_toggle.dart';
import '../device_detail/device_detail_screen.dart'
    show
        kGroupIconChoices,
        kGroupImageChoices,
        nodeDeviceGroupsProvider,
        nodeDevicesProvider,
        nodeDeviceParamsProvider;
import '../device_detail/node_service.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  final String homeId;
  final String nodeId;
  final String groupId;
  final String groupName;

  const GroupDetailScreen({
    super.key,
    required this.homeId,
    required this.nodeId,
    required this.groupId,
    required this.groupName,
  });

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  /// Device ids with an in-flight write, so only that row shows a spinner.
  final Set<String> _pending = {};

  bool _masterBusy = false;

  /// Optimistic overrides, keyed by device id.
  ///
  /// The board only reports back over MQTT a moment later, so without this the
  /// switch would snap back to its old position right after the tap and read as
  /// "the toggle didn't work" — the exact bug already fixed on the Devices tab.
  final Map<String, bool> _optimistic = {};

  Future<void> _toggleDevice(
      String deviceId, String name, String? firmwareName, bool next) async {
    setState(() {
      _pending.add(deviceId);
      _optimistic[deviceId] = next;
    });
    try {
      // Offline-tolerant: with no cloud link this first tries LOCAL control over
      // Wi-Fi (which really switches the device), then falls back to the queue
      // (design sheet #23).
      final outcome = await ref.read(commandQueueProvider.notifier).sendOrQueue(
            nodeId: widget.nodeId,
            deviceId: deviceId,
            params: {'Power': next},
            label: '$name · ${next ? 'On' : 'Off'}',
            deviceName: firmwareName,
          );
      if (outcome == SendOutcome.queued) return; // optimistic value stands
      // A LOCAL send means the cloud is unreachable, so this refetch could only
      // fail — and a failed refetch replaces the whole member list with
      // "Cannot reach SHE cloud". Instead, correct the optimistic value from the
      // board's FEEDBACK reading, exactly as the Devices tab and the online path
      // do: the switch must show what the lamp-side sense confirms, not the
      // command we sent.
      if (!ref.read(wsConnectedProvider)) {
        // Offline: mirror the two-stage ONLINE sequence. `_optimistic` already
        // shows the command; settle onto the board's FEEDBACK value after one
        // input-monitor cycle, so a light that never lit falls back to OFF.
        unawaited(_settleOnFeedback(deviceId, firmwareName));
        return;
      }
      // The board echoes the change over WS, which invalidates this provider —
      // dropping the override once the server agrees avoids a stale pin.
      ref.invalidate(nodeDeviceParamsProvider('${widget.nodeId}|$deviceId'));
    } catch (e) {
      if (!mounted) return;
      // Roll the override back so the switch does not keep claiming a state the
      // device never reached.
      setState(() => _optimistic.remove(deviceId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.errorAlt,
      ));
    } finally {
      if (mounted) setState(() => _pending.remove(deviceId));
    }
  }

  /// Settle a member's switch onto the board's FEEDBACK value after a local send.
  ///
  /// Waits past one input-monitor cycle (1 s) on purpose: the firmware writes the
  /// COMMANDED value into `last_value` first, so an immediate read returns the
  /// command rather than the lamp-side AC sense — which is what made the offline
  /// switch look like it ignored the feedback circuit.
  Future<void> _settleOnFeedback(String deviceId, String? firmwareName) async {
    if (firmwareName == null || firmwareName.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    final reported = await ref
        .read(localControlServiceProvider)
        .readReportedPower(firmwareName);
    if (reported != null && mounted) {
      setState(() => _optimistic[deviceId] = reported);
    }
  }

  Future<void> _setWholeGroup(
      List<Map<String, dynamic>> members, bool on) async {
    final deviceIds = members.map((d) => d['id'].toString()).toList();
    setState(() {
      _masterBusy = true;
      for (final id in deviceIds) {
        _optimistic[id] = on;
      }
    });
    try {
      if (!ref.read(wsConnectedProvider)) {
        // Offline: the server-side group endpoint is unreachable. Go through the
        // command path per member — it tries LOCAL control over Wi-Fi first (a
        // real switch) and only queues what the board could not take.
        final q = ref.read(commandQueueProvider.notifier);
        for (final d in members) {
          await q.sendOrQueue(
            nodeId: widget.nodeId,
            deviceId: d['id'].toString(),
            params: {'Power': on},
            label: '${widget.groupName} · All ${on ? 'on' : 'off'}',
            deviceName: d['device_name']?.toString(),
          );
        }
        return;
      }
      await ref.read(nodeServiceProvider).setDeviceGroup(widget.groupId, on);
      for (final id in deviceIds) {
        ref.invalidate(nodeDeviceParamsProvider('${widget.nodeId}|$id'));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _optimistic.clear());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.errorAlt,
      ));
    } finally {
      if (mounted) setState(() => _masterBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(nodeDeviceGroupsProvider(widget.homeId));
    final devicesAsync = ref.watch(nodeDevicesProvider(widget.nodeId));
    // Watched at the TOP of build so the whole page reliably rebuilds on every
    // device report. Watching it only inside `_body` (a nested `when` callback)
    // did NOT trigger a rebuild here, which is why the member switches lagged.
    ref.watch(livePowerProvider);

    // A provider failure is CACHED, so it does not clear itself when the link
    // comes back. Heal the page automatically instead of leaving a dead message.
    ref.listen(wsConnectedProvider, (prev, next) {
      if (next && prev != true) _retry();
    });

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: groupsAsync.when(
          loading: () =>  Center(
            child: CircularProgressIndicator(color: V3Colors.primary),
          ),
          error: (e, _) => _message(
              'Could not load the group: ${apiErrorMessage(e)}',
              onRetry: _retry),
          data: (groups) {
            final group = groups.cast<Map<String, dynamic>?>().firstWhere(
                  (g) => g?['id'].toString() == widget.groupId,
                  orElse: () => null,
                );
            // The group can vanish underneath us if it was deleted on another
            // device — say so rather than rendering an empty page.
            if (group == null) {
              return _message('This group no longer exists.');
            }
            final rawIds = (group['device_ids'] ?? group['deviceIds'])
                    as List<dynamic>? ??
                const <dynamic>[];
            final deviceIds = rawIds.map((e) => e.toString()).toList();
            final name = group['name']?.toString() ?? widget.groupName;

            return devicesAsync.when(
              loading: () =>  Center(
                child: CircularProgressIndicator(color: V3Colors.primary),
              ),
              error: (e, _) => _message(
                  'Could not load devices: ${apiErrorMessage(e)}',
                  onRetry: _retry),
              data: (devices) {
                final members = devices
                    .where((d) => deviceIds.contains(d['id'].toString()))
                    .toList();
                return _body(group, name, deviceIds, members);
              },
            );
          },
        ),
      ),
    );
  }

  /// Clears the failure chain. Both providers are leaf-ish here, but a failure is
  /// CACHED by Riverpod, so without this the page stays broken after the link
  /// returns and the user has no way back except restarting the app.
  void _retry() {
    ref.invalidate(nodeDeviceGroupsProvider(widget.homeId));
    ref.invalidate(nodeDevicesProvider(widget.nodeId));
  }

  Widget _message(String text, {VoidCallback? onRetry}) => Column(
        children: [
          SHEAppBar(title: widget.groupName, onBack: () => Navigator.pop(context)),
          Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Column(
              children: [
                Text(text,
                    textAlign: TextAlign.center,
                    style:  TextStyle(color: V3Colors.text2)),
                if (onRetry != null) ...[
                  const SizedBox(height: V3Spacing.md),
                  SHEButton(label: 'Retry', onPressed: onRetry),
                ],
              ],
            ),
          ),
        ],
      );

  Widget _body(Map<String, dynamic> group, String name, List<String> deviceIds,
      List<Map<String, dynamic>> members) {
    // Live Power per member, read from the same provider the Devices tab and the
    // R24 detail page use — the one `ws_client` invalidates on every node.state
    // event. Watched here, not inside the builder callback, because `ref.watch`
    // is unsafe in a callback.
    final live = <String, bool>{};
    // Chosen cover photo (detail hero only); null → brand gradient hero.
    final imageKey = group['image']?.toString();
    // An uploaded cover (V41) resolves to a URL; a pre-V41 row holds a bundled
    // asset key. Exactly one of these is non-null.
    final String? coverUrl =
        (imageKey != null && MediaUrls.isUploaded(imageKey))
            ? MediaUrls.resolve(imageKey)
            : null;
    final String? coverAsset = (imageKey != null &&
            imageKey != 'none' &&
            kGroupImageChoices.containsKey(imageKey) &&
            (kGroupImageChoices[imageKey] ?? '').isNotEmpty)
        ? kGroupImageChoices[imageKey]
        : null;
    final wsPower = ref.watch(livePowerProvider);
    for (final d in members) {
      final id = d['id'].toString();
      // Prefer the WS-reported value: it lands the instant the board publishes,
      // so a wall-switch change shows here without waiting for a refetch. Fall
      // back to the REST-fetched param when we have not seen an event yet.
      final ws = wsPower[id];
      if (ws != null) {
        live[id] = ws;
        continue;
      }
      ref.watch(nodeDeviceParamsProvider('${widget.nodeId}|$id')).whenData(
        (params) {
          final p = params.cast<Map<String, dynamic>?>().firstWhere(
                (x) => x?['param_name'] == 'Power',
                orElse: () => null,
              );
          if (p != null) live[id] = p['last_value'] == true;
        },
      );
    }

    // Queued intent (design sheet #23): an offline tap's target, shown until the
    // command syncs. Falls back to the in-flight optimistic value, then the board.
    final queued = <String, bool>{};
    for (final c in ref.watch(commandQueueProvider)) {
      final p = c.params['Power'];
      if (p is bool) queued[c.deviceId] = p;
    }

    bool isOn(String id) => _optimistic[id] ?? queued[id] ?? live[id] ?? false;

    return RefreshIndicator(
      color: V3Colors.primary,
      backgroundColor: V3Colors.surface,
      onRefresh: () async {
        ref.invalidate(nodeDeviceGroupsProvider(widget.homeId));
        ref.invalidate(nodeDevicesProvider(widget.nodeId));
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
            V3Spacing.md, 0, V3Spacing.md, V3Spacing.xxl),
        children: [
          SHEAppBar(title: name, onBack: () => Navigator.pop(context)),

          // ---- Hero ----
          // Ported from the Scene detail page: a centred icon over a brand
          // gradient, the name, the counts, and one full-width primary action.
          // Same page, so switching between the two feels identical.
          Container(
            decoration: BoxDecoration(
              // With a chosen cover photo, show it under a navy scrim so the
              // title stays readable; otherwise the brand gradient hero.
              gradient: (coverAsset != null || coverUrl != null)
                  ?  LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, V3Colors.night],
                      stops: [0.25, 1.0],
                    )
                  :  LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        V3Colors.heroTop,
                        V3Colors.heroMid,
                        V3Colors.heroBottom
                      ],
                    ),
              image: coverUrl != null
                  ? DecorationImage(
                      image: NetworkImage(coverUrl),
                      fit: BoxFit.cover,
                    )
                  : coverAsset != null
                      ? DecorationImage(
                          image: AssetImage(coverAsset),
                          fit: BoxFit.cover,
                        )
                      : null,
              borderRadius: BorderRadius.circular(V3Radius.xl),
              border: Border.all(color: V3Colors.border),
            ),
            padding: const EdgeInsets.all(V3Spacing.lg),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: V3Colors.primary,
                    borderRadius: BorderRadius.circular(V3Radius.lg),
                    boxShadow: [
                      BoxShadow(
                        color: V3Colors.primary.withValues(alpha: 0.55),
                        blurRadius: 44,
                        spreadRadius: -6,
                      ),
                    ],
                  ),
                  child: Center(
                    // A custom uploaded icon (V41) replaces the glyph.
                    child: SheIconOrImage(
                      value: group['icon']?.toString(),
                      fallbackIcon: (() {
                        final k = group['icon']?.toString();
                        if (k != null &&
                            k != 'auto' &&
                            kGroupIconChoices.containsKey(k)) {
                          return kGroupIconChoices[k]!;
                        }
                        return Icons.folder_special_outlined;
                      })(),
                      size: 32,
                      color: V3Colors.night,
                    ),
                  ),
                ),
                const SizedBox(height: V3Spacing.sm),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                        color: V3Colors.ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '${members.length} device(s) · '
                  '${members.where((d) => isOn(d['id'].toString())).length} on',
                  style:
                       TextStyle(color: V3Colors.text2, fontSize: 12),
                ),
                const SizedBox(height: V3Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: SHEButton(
                        label: 'All on',
                        onPressed: _masterBusy || deviceIds.isEmpty
                            ? null
                            : () => _setWholeGroup(members, true),
                      ),
                    ),
                    const SizedBox(width: V3Spacing.sm),
                    Expanded(
                      child: SHEButton(
                        label: 'All off',
                        // Secondary so "All on" stays the primary action; off is
                        // the destructive direction.
                        variant: SHEButtonVariant.secondary,
                        onPressed: _masterBusy || deviceIds.isEmpty
                            ? null
                            : () => _setWholeGroup(members, false),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: V3Spacing.lg),
          const SHESectionHeader(title: 'Devices in this group'),
          const SizedBox(height: V3Spacing.sm),

          if (members.isEmpty)
             Padding(
              padding: EdgeInsets.symmetric(vertical: V3Spacing.lg),
              child: Text(
                'No devices in this group yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: V3Colors.dim, fontSize: 12),
              ),
            )
          else
            for (final d in members) _deviceRow(d, isOn(d['id'].toString())),
        ],
      ),
    );
  }

  Widget _deviceRow(Map<String, dynamic> device, bool on) {
    final id = device['id'].toString();
    final name = device['display_name']?.toString() ??
        device['device_name']?.toString() ??
        'Device';
    final busy = _pending.contains(id);

    return Container(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.border),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: V3Spacing.md, vertical: V3Spacing.sm),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: on ? V3Colors.primary.withValues(alpha: 0.15) : V3Colors.fill,
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
            child: Icon(
              _iconFor(name),
              size: 18,
              color: on ? V3Colors.primary : V3Colors.dim,
            ),
          ),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:  TextStyle(
                    color: V3Colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          if (busy)
             Padding(
              padding: EdgeInsets.only(right: V3Spacing.sm),
              child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: V3Colors.primary)),
            ),
          SHEToggle(
            value: on,
            onChanged: (v) =>
                _toggleDevice(id, name, device['device_name']?.toString(), v),
          ),
        ],
      ),
    );
  }

  /// Bulb vs plug, so a light and a socket in the same group are distinguishable
  /// at a glance. Same keyword rule the Devices tab uses.
  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('socket') || n.contains('outlet') || n.contains('plug')) {
      return Icons.power_outlined;
    }
    if (n.contains('light') || n.contains('lamp')) return Icons.lightbulb_outline;
    return Icons.toggle_on_outlined;
  }
}
