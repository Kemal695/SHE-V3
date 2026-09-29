// =============================================================================
// SHE V3 — Device Detail Screen
// =============================================================================
// Node info + master control + custom device groups + per-device cards.
//
// Changes (2026-09-29):
//   * Every device card now carries its Power toggle in the HEADER, so a relay
//     can be switched without expanding the card.
//   * Toggles re-read their real state after a bulk change (group All-Off,
//     custom group set, rename): the parent bumps _refreshTick, which re-keys
//     the cards and forces a fresh listParams. Previously the params were
//     loaded once in initState, so a group action left every toggle stale.
//   * Devices can be renamed (PATCH /nodes/{nodeId}/devices/{deviceId}).
//   * Custom device groups: create/edit/delete + one-tap on/off, stored in the
//     backend (node_groups + node_group_members.device_id, migration V36).
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_toggle.dart';
import '../../core/widgets/haptic_slider.dart';
import 'group_control_panel.dart';
import 'node_service.dart';

final nodeDetailProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getNode(nodeId),
);

final nodeDevicesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).listDevices(nodeId),
);

/// Custom device groups for a home (backend: node_groups + node_group_members).
final nodeDeviceGroupsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, homeId) => ref.read(nodeServiceProvider).listDeviceGroups(homeId),
);

/// Per-device params, keyed `'<nodeId>|<deviceId>'`.
///
/// Deliberately a PROVIDER and not widget state. The backend pushes a WebSocket
/// `node.state` event for every param the device reports (MqttSubscriberService
/// → WsEventBus.publishNodeState), and WsClient invalidates exactly this
/// provider. That is what makes a switch follow the REAL relay state within a
/// second — including changes made from the master group buttons, a scene, an
/// automation, or another phone. Previously the params were loaded once in
/// initState and nothing could ever refresh them, so the toggle went stale.
final nodeDeviceParamsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, key) {
  final parts = key.split('|');
  return ref.read(nodeServiceProvider).listParams(parts[0], parts[1]);
});

class DeviceDetailScreen extends ConsumerStatefulWidget {
  final String nodeId;

  const DeviceDetailScreen({super.key, required this.nodeId});

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  /// Bumped whenever something changes MANY channels at once (group set) or the
  /// device list itself (rename). Re-keys the device cards so they reload params.
  int _refreshTick = 0;

  void _bump() {
    if (mounted) setState(() => _refreshTick++);
  }

  /// The device reports back over MQTT a moment after a group command, so an
  /// immediate reload would still read the old cached value. The WebSocket
  /// `node.state` event normally refreshes the toggles on its own; this is the
  /// belt-and-braces fallback for when the socket is down.
  void _bumpSoon() {
    Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      ref.invalidate(nodeDeviceParamsProvider);
      ref.invalidate(nodeDevicesProvider(widget.nodeId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final nodeAsync = ref.watch(nodeDetailProvider(widget.nodeId));
    final devicesAsync = ref.watch(nodeDevicesProvider(widget.nodeId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: V3Colors.textPrimary),
          onPressed: () => context.go('/dashboard'),
        ),
        title: nodeAsync.when(
          loading: () => const Text('Device'),
          error: (_, __) => const Text('Device'),
          data: (node) => Text(node['name'] ?? node['node_id'] ?? 'Device'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bolt_outlined, color: V3Colors.warning),
            onPressed: () => context.push('/node/${widget.nodeId}/energy'),
            tooltip: 'Energy',
          ),
        ],
      ),
      body: SafeArea(
        child: nodeAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(
                color: V3Colors.primary, strokeWidth: 3),
          ),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(V3Spacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline,
                      size: 48, color: V3Colors.error),
                  const SizedBox(height: V3Spacing.md),
                  Text('Failed to load device',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: V3Spacing.sm),
                  Text(err.toString(),
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
          data: (node) {
            return devicesAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(
                    color: V3Colors.primary, strokeWidth: 3),
              ),
              error: (err, _) => Center(child: Text('Error: $err')),
              data: (devices) => _buildDeviceList(context, node, devices),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDeviceList(BuildContext context,
      Map<String, dynamic> node, List<Map<String, dynamic>> devices) {
    final isOnline = node['is_online'] ?? false;
    final sku = node['sku'] ?? 'SHE-R8';
    final firmware = node['firmware_version'] ?? 'Unknown';
    final homeId = node['home_id']?.toString();

    return ListView(
      padding: const EdgeInsets.all(V3Spacing.md),
      children: [
        // ---- Node info card ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.md),
            child: Row(
              children: [
                Icon(_iconForSku(sku),
                    size: 32,
                    color: isOnline
                        ? V3Colors.primary
                        : V3Colors.textSecondary),
                const SizedBox(width: V3Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node['name'] ?? 'Device',
                          style: Theme.of(context).textTheme.titleLarge),
                      Text('$sku · $firmware',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (isOnline
                            ? V3Colors.success
                            : V3Colors.textSecondary)
                        .withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isOnline
                              ? V3Colors.success
                              : V3Colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: TextStyle(
                          color: isOnline
                              ? V3Colors.success
                              : V3Colors.textSecondary,
                          fontSize: V3Typography.captionSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: V3Spacing.md),

        // ---- Master / group control (ADR-015) ----
        GroupControlPanel(
          nodeId: widget.nodeId,
          sku: sku,
          onChanged: _bumpSoon,
        ),

        // ---- Custom device groups ----
        if (homeId != null && homeId.isNotEmpty)
          _GroupsSection(
            homeId: homeId,
            nodeId: widget.nodeId,
            devices: devices,
            onChanged: _bumpSoon,
          ),

        // ---- Devices section header ----
        Text('Devices (${devices.length})',
            style: const TextStyle(
              color: V3Colors.textSecondary,
              fontSize: V3Typography.overlineSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            )),
        const SizedBox(height: V3Spacing.sm),

        // ---- Device cards (re-keyed on _refreshTick so params reload) ----
        ...devices.map((device) => _DeviceCard(
              key: ValueKey('${device['id']}-$_refreshTick'),
              nodeId: widget.nodeId,
              device: device,
              onChanged: _bump,
            )),
      ],
    );
  }

  IconData _iconForSku(String sku) => switch (sku) {
        'SHE-R4' => Icons.power,
        'SHE-R8' => Icons.dashboard,
        'SHE-R16' => Icons.developer_board,
        _ => Icons.device_unknown,
      };
}

// =============================================================================
// _GroupsSection — custom device groups (create / edit / delete / on / off)
// =============================================================================
class _GroupsSection extends ConsumerStatefulWidget {
  final String homeId;
  final String nodeId;
  final List<Map<String, dynamic>> devices;
  final VoidCallback onChanged;

  const _GroupsSection({
    required this.homeId,
    required this.nodeId,
    required this.devices,
    required this.onChanged,
  });

  @override
  ConsumerState<_GroupsSection> createState() => _GroupsSectionState();
}

class _GroupsSectionState extends ConsumerState<_GroupsSection> {
  String? _busyId;

  /// Groups whose member devices are revealed inline (so each relay in the group
  /// can still be switched on its own).
  final Set<String> _expanded = {};

  Future<void> _openEditor({Map<String, dynamic>? existing}) async {
    final result = await showDialog<_GroupEditResult>(
      context: context,
      builder: (_) => _GroupEditorDialog(
        devices: widget.devices,
        existing: existing,
      ),
    );
    if (result == null) return;

    try {
      final svc = ref.read(nodeServiceProvider);
      if (existing == null) {
        await svc.createDeviceGroup(
            widget.homeId, result.name, result.deviceIds);
      } else {
        await svc.updateDeviceGroup(
            existing['id'].toString(), result.name, result.deviceIds);
      }
      ref.invalidate(nodeDeviceGroupsProvider(widget.homeId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('${result.name}: ${result.deviceIds.length} device(s) saved'),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.error,
      ));
    }
  }

  Future<void> _set(Map<String, dynamic> group, bool on) async {
    final id = group['id'].toString();
    setState(() => _busyId = id);
    try {
      await ref.read(nodeServiceProvider).setDeviceGroup(id, on);
      widget.onChanged();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${group['name']} turned ${on ? 'on' : 'off'}'),
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.error,
      ));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _delete(Map<String, dynamic> group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: V3Colors.surface,
        title: const Text('Delete group?',
            style: TextStyle(color: V3Colors.textPrimary)),
        content: Text('Delete "${group['name']}"? The devices are not affected.',
            style: const TextStyle(color: V3Colors.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Delete', style: TextStyle(color: V3Colors.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(nodeServiceProvider)
          .deleteDeviceGroup(group['id'].toString());
      ref.invalidate(nodeDeviceGroupsProvider(widget.homeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(nodeDeviceGroupsProvider(widget.homeId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('GROUPS',
                style: TextStyle(
                  color: V3Colors.textSecondary,
                  fontSize: V3Typography.overlineSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                )),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 18, color: V3Colors.primary),
              label: const Text('New group',
                  style: TextStyle(color: V3Colors.primary, fontSize: 13)),
            ),
          ],
        ),
        groupsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(V3Spacing.sm),
            child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: V3Colors.primary)),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(V3Spacing.sm),
            child: Text('Could not load groups: ${apiErrorMessage(e)}',
                style: const TextStyle(
                    color: V3Colors.error,
                    fontSize: V3Typography.captionSize)),
          ),
          data: (groups) {
            if (groups.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(bottom: V3Spacing.sm),
                child: Text(
                    'No groups yet — create one to switch several relays '
                    'together.',
                    style: TextStyle(
                        color: V3Colors.textSecondary,
                        fontSize: V3Typography.captionSize)),
              );
            }
            return Column(
              children: groups.map((g) => _groupCard(context, g)).toList(),
            );
          },
        ),
        const SizedBox(height: V3Spacing.md),
      ],
    );
  }

  Widget _groupCard(BuildContext context, Map<String, dynamic> group) {
    final id = group['id'].toString();
    // The backend serialises this as `device_ids` (see GroupOut); accept the
    // camelCase form too so a field-name drift can never silently empty a group.
    final rawIds =
        (group['device_ids'] ?? group['deviceIds']) as List<dynamic>? ??
            const <dynamic>[];
    final deviceIds = rawIds.map((e) => e.toString()).toList();
    final busy = _busyId == id;
    final expanded = _expanded.contains(id);
    // Resolve members from the device list we already have, so each one can be
    // switched on its own without leaving the group.
    final members = widget.devices
        .where((d) => deviceIds.contains(d['id'].toString()))
        .toList();

    return Card(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- Header row (everything vertically centred) ----
          InkWell(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(id);
              } else {
                _expanded.add(id);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: V3Spacing.md, vertical: V3Spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Leading icon — fixed width so every title lines up.
                  const SizedBox(
                    width: 28,
                    child: Icon(Icons.folder_special_outlined,
                        size: 22, color: V3Colors.primary),
                  ),
                  const SizedBox(width: V3Spacing.sm),
                  // Title block
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          group['name']?.toString() ?? 'Group',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: V3Colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: V3Typography.titleSize - 4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${deviceIds.length} device(s) · tap to '
                          '${expanded ? 'hide' : 'control each'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: V3Colors.textSecondary,
                            fontSize: V3Typography.captionSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Breathing room so the title can never wrap into the buttons.
                  const SizedBox(width: 8),
                  // Action controls
                  if (busy)
                    const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: V3Colors.primary))
                  else ...[
                    _miniButton('On', V3Colors.success, () => _set(group, true)),
                    const SizedBox(width: 6),
                    _miniButton('Off', V3Colors.error, () => _set(group, false)),
                  ],
                  // Trailing: menu + chevron
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      iconSize: 20,
                      icon: const Icon(Icons.more_vert,
                          size: 20, color: V3Colors.textSecondary),
                      onSelected: (v) {
                        if (v == 'edit') _openEditor(existing: group);
                        if (v == 'delete') _delete(group);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: V3Colors.textSecondary),
                ],
              ),
            ),
          ),
          // ---- Content area: members, or a centred empty state ----
          if (expanded) ...[
            const Divider(height: 1, thickness: 0.5, color: Color(0x1FFFFFFF)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  V3Spacing.sm, V3Spacing.sm, V3Spacing.sm, V3Spacing.sm),
              child: members.isEmpty
                  ? const Padding(
                      padding:
                          EdgeInsets.symmetric(vertical: V3Spacing.lg),
                      child: Center(
                        child: Text(
                          'No devices in this group yet.',
                          style: TextStyle(
                              color: V3Colors.textSecondary,
                              fontSize: V3Typography.captionSize),
                        ),
                      ),
                    )
                  : Column(
                      children: members
                          .map((d) => _DeviceCard(
                                key: ValueKey('grp-$id-${d['id']}'),
                                nodeId: widget.nodeId,
                                device: d,
                                onChanged: widget.onChanged,
                              ))
                          .toList(),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniButton(String text, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 30,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: V3Spacing.sm),
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
      ),
    );
  }
}

class _GroupEditResult {
  final String name;
  final List<String> deviceIds;
  const _GroupEditResult(this.name, this.deviceIds);
}

class _GroupEditorDialog extends StatefulWidget {
  final List<Map<String, dynamic>> devices;
  final Map<String, dynamic>? existing;

  const _GroupEditorDialog({required this.devices, this.existing});

  @override
  State<_GroupEditorDialog> createState() => _GroupEditorDialogState();
}

class _GroupEditorDialogState extends State<_GroupEditorDialog> {
  late final TextEditingController _name;
  late final Set<String> _selected;

  /// Inline validation. The previous build returned silently on an empty name,
  /// which reads exactly like "the Create button does nothing".
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
        text: widget.existing?['name']?.toString() ?? '');
    final raw = (widget.existing?['device_ids'] ??
        widget.existing?['deviceIds']) as List<dynamic>? ?? const <dynamic>[];
    _selected = {...raw.map((e) => e.toString())};
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Validate, then pop with the result.
  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a group name');
      return;
    }
    Navigator.pop(context, _GroupEditResult(name, _selected.toList()));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final selectable =
        widget.devices.where((d) => !(d['is_service'] ?? false)).toList();

    return Dialog(
      backgroundColor: V3Colors.surface,
      insetPadding: const EdgeInsets.all(V3Spacing.lg),
      child: ConstrainedBox(
        // A hard height cap makes the Flexible below safe: a flex child needs a
        // bounded height, and an AlertDialog does not always provide one — when
        // that failed the device list never laid out, nothing could be ticked,
        // and the group was created with zero members.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          maxWidth: 380,
        ),
        child: Padding(
          padding: const EdgeInsets.all(V3Spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isEdit ? 'Edit group' : 'New group',
                  style: const TextStyle(
                      color: V3Colors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: V3Spacing.md),
              TextField(
                controller: _name,
                style: const TextStyle(color: V3Colors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Group name',
                  labelStyle: const TextStyle(color: V3Colors.textSecondary),
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              const SizedBox(height: V3Spacing.md),
              Row(
                children: [
                  Text('Devices (${_selected.length} selected)',
                      style: const TextStyle(
                          color: V3Colors.textSecondary,
                          fontSize: V3Typography.captionSize)),
                  const Spacer(),
                  TextButton(
                    onPressed: selectable.isEmpty
                        ? null
                        : () => setState(() {
                              if (_selected.length == selectable.length) {
                                _selected.clear();
                              } else {
                                _selected
                                  ..clear()
                                  ..addAll(
                                      selectable.map((d) => d['id'].toString()));
                              }
                            }),
                    child: Text(
                        _selected.length == selectable.length
                            ? 'Clear all'
                            : 'Select all',
                        style: const TextStyle(
                            color: V3Colors.primary, fontSize: 12)),
                  ),
                ],
              ),
              Flexible(
                child: selectable.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(V3Spacing.md),
                        child: Text('No devices found for this home.',
                            style: TextStyle(color: V3Colors.textSecondary)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: selectable.length,
                        itemBuilder: (_, i) {
                          final d = selectable[i];
                          final id = d['id'].toString();
                          final name = d['display_name'] ??
                              d['device_name'] ??
                              'Device';
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: _selected.contains(id),
                            activeColor: V3Colors.primary,
                            title: Text(name,
                                style: const TextStyle(
                                    color: V3Colors.textPrimary,
                                    fontSize: 14)),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(id);
                              } else {
                                _selected.remove(id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              if (_selected.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: V3Spacing.sm),
                  child: Text('Tick the relays you want in this group.',
                      style: TextStyle(
                          color: V3Colors.warning,
                          fontSize: V3Typography.captionSize)),
                ),
              const SizedBox(height: V3Spacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  const SizedBox(width: V3Spacing.sm),
                  FilledButton(
                    onPressed: _submit,
                    child: Text(isEdit ? 'Save' : 'Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _DeviceCard — one device: header toggle (no expand needed) + params + rename
// =============================================================================
class _DeviceCard extends ConsumerStatefulWidget {
  final String nodeId;
  final Map<String, dynamic> device;
  final VoidCallback onChanged;

  const _DeviceCard({
    super.key,
    required this.nodeId,
    required this.device,
    required this.onChanged,
  });

  @override
  ConsumerState<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<_DeviceCard> {
  bool _expanded = false;
  bool _powerBusy = false;
  bool? _powerOptimistic;

  /// Provider key for THIS device's params (see nodeDeviceParamsProvider).
  String get _paramsKey => '${widget.nodeId}|${widget.device['id']}';

  static Map<String, dynamic>? _powerParamIn(
      List<Map<String, dynamic>> params) {
    for (final p in params) {
      if (p['param_name'] == 'Power') return p;
    }
    return null;
  }

  /// While a write is in flight we show the intended value; once it settles the
  /// REAL reported state (REST refetch or a WebSocket node.state event) wins.
  bool _powerOn(List<Map<String, dynamic>> params) {
    if (_powerBusy && _powerOptimistic != null) return _powerOptimistic!;
    return _powerParamIn(params)?['last_value'] == true;
  }

  bool _powerWritable(List<Map<String, dynamic>> params) {
    final p = _powerParamIn(params);
    if (p == null) return false;
    final props = p['properties'];
    if (props is List) return props.contains('write');
    return true;
  }

  String _displayName() => (widget.device['display_name'] ??
          widget.device['device_name'] ??
          'Device')
      .toString();

  Future<void> _writePower(bool value) async {
    setState(() {
      _powerOptimistic = value;
      _powerBusy = true;
    });
    try {
      await ref.read(nodeServiceProvider).writeParams(
        widget.nodeId,
        widget.device['id'],
        {'Power': value},
      );
      // Refetch this device's params. writeParams updates node_params.last_value
      // (desired state) immediately, and the device's own params/local report
      // arrives as a WebSocket node.state event — both land in this provider.
      ref.invalidate(nodeDeviceParamsProvider(_paramsKey));
      // Hold the optimistic position only briefly; after that the real reported
      // state takes over (so an unacknowledged write can't lie indefinitely).
      Timer(const Duration(milliseconds: 900), () {
        if (mounted) {
          setState(() {
            _powerOptimistic = null;
            _powerBusy = false;
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _powerOptimistic = null;
        _powerBusy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to switch ${_displayName()}'),
        backgroundColor: V3Colors.error,
      ));
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _displayName());
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: V3Colors.surface,
        title: const Text('Rename device',
            style: TextStyle(color: V3Colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: V3Colors.textPrimary),
          decoration: const InputDecoration(
            labelText: 'Display name',
            labelStyle: TextStyle(color: V3Colors.textSecondary),
            helperText: 'Leave empty to use the default name',
            helperStyle: TextStyle(color: V3Colors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save',
                  style: TextStyle(color: V3Colors.primary))),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    try {
      await ref.read(nodeServiceProvider).renameDevice(
            widget.nodeId,
            widget.device['id'].toString(),
            result.isEmpty ? null : result,
          );
      // Reload the device list so the new name shows everywhere.
      ref.invalidate(nodeDevicesProvider(widget.nodeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(apiErrorMessage(e)),
        backgroundColor: V3Colors.error,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isService = widget.device['is_service'] ?? false;
    final type = widget.device['device_type']?.toString() ?? '';

    // Live params — refetched whenever the WS reports node.state for this device.
    final paramsAsync = ref.watch(nodeDeviceParamsProvider(_paramsKey));
    final params = paramsAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final canToggle =
        !isService && _powerParamIn(params) != null && _powerWritable(params);

    return Card(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: Column(
        children: [
          // ---- Header: tap to expand, toggle + menu always visible ----
          InkWell(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: V3Spacing.md, vertical: V3Spacing.sm),
              child: Row(
                children: [
                  Icon(
                    isService ? Icons.settings_outlined : Icons.power,
                    color:
                        isService ? V3Colors.textSecondary : V3Colors.primary,
                    size: 24,
                  ),
                  const SizedBox(width: V3Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_displayName(),
                            style: const TextStyle(
                              color: V3Colors.textPrimary,
                              fontSize: V3Typography.titleSize - 2,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(type,
                            style: const TextStyle(
                              color: V3Colors.textSecondary,
                              fontSize: V3Typography.captionSize,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  // Inline Power toggle — visible without expanding.
                  if (canToggle)
                    SHEToggle(value: _powerOn(params), onChanged: _writePower)
                  else if (paramsAsync.isLoading)
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: V3Colors.primary)),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        size: 20, color: V3Colors.textSecondary),
                    onSelected: (v) {
                      if (v == 'rename') _rename();
                      if (v == 'expand') {
                        setState(() => _expanded = !_expanded);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                          value: 'expand',
                          child:
                              Text(_expanded ? 'Hide details' : 'Details')),
                    ],
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: V3Colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          // ---- Expanded body: params ----
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: V3Spacing.md,
                right: V3Spacing.md,
                bottom: V3Spacing.md,
              ),
              child: paramsAsync.isLoading
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: V3Colors.primary),
                    )
                  : paramsAsync.hasError
                      ? const Text('Failed to load params',
                          style: TextStyle(color: V3Colors.error))
                      : params.isEmpty
                          ? const Text('No parameters',
                              style:
                                  TextStyle(color: V3Colors.textSecondary))
                          : Column(
                              children: params
                                  .map((param) => _ParamRow(
                                        nodeId: widget.nodeId,
                                        deviceId: widget.device['id'],
                                        param: param,
                                        onUpdate: () => ref.invalidate(
                                            nodeDeviceParamsProvider(
                                                _paramsKey)),
                                      ))
                                  .toList(),
                            ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ParamRow — renders a single param with its control
// =============================================================================
class _ParamRow extends ConsumerStatefulWidget {
  final String nodeId;
  final String deviceId;
  final Map<String, dynamic> param;
  final VoidCallback onUpdate;

  const _ParamRow({
    required this.nodeId,
    required this.deviceId,
    required this.param,
    required this.onUpdate,
  });

  @override
  ConsumerState<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends ConsumerState<_ParamRow> {
  bool _toggling = false;
  dynamic _optimisticValue;

  @override
  Widget build(BuildContext context) {
    final paramName = widget.param['param_name'] as String? ?? '';
    final dataType = widget.param['data_type'] as String? ?? 'string';
    final uiHint = widget.param['ui_hint'] as String?;
    final props = widget.param['properties'];
    final readOnly = props is List && !props.contains('write');

    final currentValue = _optimisticValue ?? widget.param['last_value'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: V3Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              paramName,
              style: const TextStyle(
                color: V3Colors.textPrimary,
                fontSize: V3Typography.bodySize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (dataType == 'bool' &&
              (uiHint == 'toggle' || uiHint == null) &&
              !readOnly)
            _toggling
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: V3Colors.primary),
                  )
                : SHEToggle(
                    value: currentValue == true,
                    onChanged: (v) => _writeParam(v),
                  )
          else if ((dataType == 'int' || dataType == 'float') &&
              uiHint == 'slider' &&
              !readOnly)
            SizedBox(
              width: 150,
              child: HapticSlider(
                value: (currentValue as num?)?.toDouble() ?? 0,
                min: (widget.param['min_value'] as num?)?.toDouble() ?? 0,
                max: (widget.param['max_value'] as num?)?.toDouble() ?? 100,
                snapIncrement: dataType == 'int' ? 1.0 : 0.5,
                onChanged: (v) => _writeParam(dataType == 'int' ? v.toInt() : v),
              ),
            )
          else
            Text(
              '${currentValue ?? '-'}',
              style: const TextStyle(
                color: V3Colors.textSecondary,
                fontSize: V3Typography.bodySize,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _writeParam(dynamic value) async {
    final paramName = widget.param['param_name'] as String? ?? '';

    setState(() => _optimisticValue = value);
    if (value is bool) {
      setState(() => _toggling = true);
    }

    try {
      await ref.read(nodeServiceProvider).writeParams(
        widget.nodeId,
        widget.deviceId,
        {paramName: value},
      );
      if (mounted) {
        setState(() {
          _optimisticValue = null;
          _toggling = false;
        });
        widget.onUpdate();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _optimisticValue = null;
          _toggling = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update $paramName'),
            backgroundColor: V3Colors.error,
          ),
        );
      }
    }
  }
}
