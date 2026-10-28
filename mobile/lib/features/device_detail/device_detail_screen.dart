// =============================================================================
// SHE V3 — Device Detail Screen (board page)
// =============================================================================
// Shows ONE board (e.g. "R24 test board") and the devices inside it as a flat
// list of toggle tiles — the SAME style as the Devices tab. No groups, no
// master control: this page is intentionally a "device page" for a single
// board, mirroring the user's own Devices tab.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error.dart';
import '../../core/network/device_kind.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../voice/voice_hold_button.dart';
import 'node_service.dart';

final nodeDetailProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getNode(nodeId),
);

final nodeDevicesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).listDevices(nodeId),
);

/// Per-device params, keyed `'<nodeId>|<deviceId>'`. Invalidated by WsClient on
/// every `node.state` event, so a switch follows the REAL relay state.
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
  @override
  Widget build(BuildContext context) {
    final nodeAsync = ref.watch(nodeDetailProvider(widget.nodeId));
    final devicesAsync = ref.watch(nodeDevicesProvider(widget.nodeId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: V3Colors.textPrimary),
          onPressed: () => context.go('/dashboard'),
        ),
        title: nodeAsync.when(
          loading: () => const Text('Device'),
          error: (_, __) => const Text('Device'),
          data: (node) => Text(node['name'] ?? node['node_id'] ?? 'Device'),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.bolt_outlined, color: V3Colors.warning),
            onPressed: () => context.push('/node/${widget.nodeId}/energy'),
            tooltip: 'Energy',
          ),
        ],
      ),
      // Push-to-talk voice control, on the board page: hold to record.
      floatingActionButton: const VoiceHoldButton(),
      body: SafeArea(
        child: nodeAsync.when(
          loading: () => Center(
            child: CircularProgressIndicator(
                color: V3Colors.primary, strokeWidth: 3),
          ),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(V3Spacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: V3Colors.error),
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
              loading: () => Center(
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
    final name = node['name']?.toString() ?? 'Device';

    return ListView(
      padding: const EdgeInsets.all(V3Spacing.md),
      children: [
        // ---- Compact board header (device-page style) ----
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: V3Colors.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: isOnline
                              ? V3Colors.successAlt
                              : V3Colors.dim,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text('$sku · ${isOnline ? 'Online' : 'Offline'}',
                          style: TextStyle(color: V3Colors.text2, fontSize: 12)),
                      const SizedBox(width: 8),
                      Text(firmware,
                          style: TextStyle(
                              color: V3Colors.textSecondary, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: V3Spacing.md),

        // ---- Devices (flat, device-page style) ----
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: V3Spacing.lg),
            child: Text('No devices in this board.',
                style: TextStyle(color: V3Colors.textSecondary)),
          )
        else
          ...devices.map((device) => _DeviceCard(
                key: ValueKey(device['id']),
                nodeId: widget.nodeId,
                device: device,
                isOnline: isOnline,
              )),
      ],
    );
  }
}

class _DeviceCard extends ConsumerStatefulWidget {
  final String nodeId;
  final Map<String, dynamic> device;
  final bool isOnline;

  const _DeviceCard({
    super.key,
    required this.nodeId,
    required this.device,
    required this.isOnline,
  });

  @override
  ConsumerState<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<_DeviceCard> {
  bool _powerBusy = false;
  bool? _powerOptimistic;

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
    final p = _powerParamIn(params);
    if (p != null) {
      final reported = p['reported_value'];
      if (reported != null) return reported == true;
      return p['last_value'] == true;
    }
    return false;
  }

  bool _powerWritable(List<Map<String, dynamic>> params) {
    final p = _powerParamIn(params);
    if (p == null) return false;
    final props = p['properties'];
    if (props is List) return props.contains('write');
    return true;
  }

  String _displayName() =>
      (widget.device['display_name'] ?? widget.device['device_name'] ?? 'Device')
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
      ref.invalidate(nodeDeviceParamsProvider(_paramsKey));
      // Hold the optimistic position only briefly; after that the real reported
      // state takes over.
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
        title: Text('Rename device',
            style: TextStyle(color: V3Colors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: V3Colors.textPrimary),
          decoration: InputDecoration(
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
            child: Text('Save', style: TextStyle(color: V3Colors.primary)),
          ),
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
    final paramsAsync = ref.watch(nodeDeviceParamsProvider(_paramsKey));
    final params = paramsAsync.valueOrNull ?? const <Map<String, dynamic>>[];
    final canToggle =
        !isService && _powerParamIn(params) != null && _powerWritable(params);
    final kind = kindFromDeviceType(type, name: _displayName());
    final on = _powerOn(params) && widget.isOnline;

    return Card(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            DeviceIcon(kind: kind, on: on, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _displayName(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: V3Colors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      SHEStatusBadge(online: widget.isOnline),
                      if (on && widget.isOnline) ...[
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
            if (canToggle)
              IconButton(
                tooltip: 'Rename device',
                onPressed: _rename,
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(Icons.edit_outlined, color: V3Colors.textSecondary),
              ),
            SHEToggle(
              value: on,
              enabled: canToggle,
              onChanged: (v) => _writePower(v),
            ),
          ],
        ),
      ),
    );
  }
}
