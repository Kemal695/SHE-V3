// =============================================================================
// SHE V3 — Device detail screen
// =============================================================================
// V3-MOBILE-APP §5. Shows node config + devices + params.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/she_theme.dart';
import 'node_service.dart';

final nodeDetailProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getNode(nodeId),
);

final nodeDevicesProvider = FutureProvider.family<List<Map<String, dynamic>>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).listDevices(nodeId),
);

class DeviceDetailScreen extends ConsumerWidget {
  final String nodeId;

  const DeviceDetailScreen({super.key, required this.nodeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeAsync = ref.watch(nodeDetailProvider(nodeId));
    final devicesAsync = ref.watch(nodeDevicesProvider(nodeId));

    return Scaffold(
      appBar: AppBar(
        title: nodeAsync.when(
          loading: () => const Text('Device'),
          error: (_, __) => const Text('Device'),
          data: (node) => Text(node['name'] ?? node['node_id'] ?? 'Device'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bolt),
            onPressed: () => context.push('/node/$nodeId/energy'),
            tooltip: 'Energy',
          ),
        ],
      ),
      body: SafeArea(
        child: nodeAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(child: Text('Error: $err')),
          data: (node) {
            return devicesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('Error: $err')),
              data: (devices) {
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final device = devices[index];
                    return _DeviceCard(
                      nodeId: nodeId,
                      device: device,
                      ref: ref,
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DeviceCard extends ConsumerStatefulWidget {
  final String nodeId;
  final Map<String, dynamic> device;
  final WidgetRef ref;

  const _DeviceCard({required this.nodeId, required this.device, required this.ref});

  @override
  ConsumerState<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<_DeviceCard> {
  List<Map<String, dynamic>>? _params;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadParams();
  }

  Future<void> _loadParams() async {
    try {
      final params = await widget.ref.read(nodeServiceProvider)
          .listParams(widget.nodeId, widget.device['id']);
      if (mounted) {
        setState(() {
          _params = params;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isService = widget.device['is_service'] ?? false;
    final name = widget.device['display_name'] ?? widget.device['device_name'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isService ? Icons.settings : Icons.power,
                  color: isService ? SheTheme.textMuted : SheTheme.brightSkyBlue,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        widget.device['device_type'] ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else if (_params != null)
              ..._params!.map((param) => _ParamRow(
                    nodeId: widget.nodeId,
                    deviceId: widget.device['id'],
                    param: param,
                  )),
          ],
        ),
      ),
    );
  }
}

class _ParamRow extends ConsumerStatefulWidget {
  final String nodeId;
  final String deviceId;
  final Map<String, dynamic> param;

  const _ParamRow({required this.nodeId, required this.deviceId, required this.param});

  @override
  ConsumerState<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends ConsumerState<_ParamRow> {
  bool _toggling = false;

  Future<void> _toggle(bool value) async {
    final oldValue = widget.param['last_value'];
    setState(() {
      widget.param['last_value'] = value;
      _toggling = true;
    });
    try {
      await ref.read(nodeServiceProvider).writeParams(
        widget.nodeId,
        widget.deviceId,
        {widget.param['param_name']: value},
      );
      ref.invalidate(nodeDevicesProvider(widget.nodeId));
    } catch (e) {
      if (mounted) {
        setState(() {
          widget.param['last_value'] = oldValue;
        });
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paramName = widget.param['param_name'];
    final dataType = widget.param['data_type'];
    final uiHint = widget.param['ui_hint'];
    final lastValue = widget.param['last_value'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(paramName, style: Theme.of(context).textTheme.bodyMedium),
          if (dataType == 'bool' && uiHint == 'toggle')
            _toggling
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Switch(
                    value: lastValue == true,
                    onChanged: _toggle,
                  )
          else if (dataType == 'int' && uiHint == 'slider')
            Text('${lastValue ?? 0}', style: Theme.of(context).textTheme.bodyMedium)
          else
            Text('${lastValue ?? '-'}', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
