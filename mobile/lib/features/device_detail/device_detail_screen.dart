// =============================================================================
// SHE V3 — Device Detail Screen
// =============================================================================
// Shows node info + device cards with params. No overflow (ListView).
// Back button works properly (go_router default).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_toggle.dart';
import '../../core/widgets/haptic_slider.dart';
import 'node_service.dart';

final nodeDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>(
  (ref, nodeId) => ref.read(nodeServiceProvider).getNode(nodeId),
);

final nodeDevicesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
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
          // Energy button (only for R8/R16 with PZEM)
          IconButton(
            icon: const Icon(Icons.bolt_outlined, color: V3Colors.warning),
            onPressed: () => context.push('/node/$nodeId/energy'),
            tooltip: 'Energy',
          ),
        ],
      ),
      body: SafeArea(
        child: nodeAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: V3Colors.primary, strokeWidth: 3),
          ),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(V3Spacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: V3Colors.error),
                  const SizedBox(height: V3Spacing.md),
                  Text('Failed to load device', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: V3Spacing.sm),
                  Text(err.toString(), style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
          data: (node) {
            return devicesAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: V3Colors.primary, strokeWidth: 3),
              ),
              error: (err, _) => Center(child: Text('Error: $err')),
              data: (devices) => _buildDeviceList(context, ref, node, devices),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDeviceList(BuildContext context, WidgetRef ref,
      Map<String, dynamic> node, List<Map<String, dynamic>> devices) {
    final isOnline = node['is_online'] ?? false;
    final sku = node['sku'] ?? 'SHE-R8';
    final firmware = node['firmware_version'] ?? 'Unknown';

    return ListView(
      padding: const EdgeInsets.all(V3Spacing.md),
      children: [
        // ---- Node info card ----
        Card(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_iconForSku(sku), size: 32,
                        color: isOnline ? V3Colors.primary : V3Colors.textSecondary),
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
                    // Online/offline badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: (isOnline ? V3Colors.success : V3Colors.textSecondary)
                            .withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(V3Radius.full),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isOnline ? V3Colors.success : V3Colors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                              color: isOnline ? V3Colors.success : V3Colors.textSecondary,
                              fontSize: V3Typography.captionSize,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: V3Spacing.md),

        // ---- Devices section header ----
        Text('Devices (${devices.length})',
            style: const TextStyle(
              color: V3Colors.textSecondary,
              fontSize: V3Typography.overlineSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            )),
        const SizedBox(height: V3Spacing.sm),

        // ---- Device cards ----
        ...devices.map((device) => _DeviceCard(
              nodeId: nodeId,
              device: device,
              ref: ref,
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
// _DeviceCard — renders one device with its params
// =============================================================================
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadParams();
  }

  Future<void> _loadParams() async {
    try {
      final params = await widget.ref.read(nodeServiceProvider).listParams(
            widget.nodeId,
            widget.device['id'],
          );
      if (mounted) {
        setState(() {
          _params = params;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isService = widget.device['is_service'] ?? false;
    final name = widget.device['display_name'] ?? widget.device['device_name'];
    final type = widget.device['device_type'] ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V3Radius.lg),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V3Radius.lg),
        ),
        leading: Icon(
          isService ? Icons.settings_outlined : Icons.power,
          color: isService ? V3Colors.textSecondary : V3Colors.primary,
          size: 24,
        ),
        title: Text(name, style: const TextStyle(
          color: V3Colors.textPrimary,
          fontSize: V3Typography.titleSize - 2,
          fontWeight: FontWeight.w600,
        )),
        subtitle: Text(type, style: const TextStyle(
          color: V3Colors.textSecondary,
          fontSize: V3Typography.captionSize,
        )),
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(V3Spacing.md),
              child: SizedBox(
                height: 24, width: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: V3Colors.primary),
              ),
            )
          else if (_error != null)
            const Padding(
              padding: EdgeInsets.all(V3Spacing.md),
              child: Text('Failed to load params', style: TextStyle(color: V3Colors.error)),
            )
          else if (_params != null && _params!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: V3Spacing.md,
                right: V3Spacing.md,
                bottom: V3Spacing.md,
              ),
              child: Column(
                children: _params!.map((param) => _ParamRow(
                  nodeId: widget.nodeId,
                  deviceId: widget.device['id'],
                  param: param,
                  onUpdate: () => _loadParams(),
                )).toList(),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(V3Spacing.md),
              child: Text('No parameters', style: TextStyle(color: V3Colors.textSecondary)),
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
    final readOnly = widget.param['properties']?.contains('write') == false;

    // Use optimistic value if set, otherwise last_value
    final currentValue = _optimisticValue ?? widget.param['last_value'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: V3Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Param name
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
          // Control
          if (dataType == 'bool' && (uiHint == 'toggle' || uiHint == null) && !readOnly)
            _toggling
                ? const SizedBox(
                    width: 24, height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: V3Colors.primary),
                  )
                : SHEToggle(
                    value: currentValue == true,
                    onChanged: (v) => _writeParam(v),
                  )
          else if ((dataType == 'int' || dataType == 'float') && uiHint == 'slider' && !readOnly)
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
    // `paramName` is a local in the row builder, so it was out of scope here and
    // both the request body and the error message referenced an undefined name.
    // Derive it from the same source the builder uses.
    final paramName = widget.param['param_name'] as String? ?? '';

    // Optimistic UI update
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
      // Clear optimistic — actual value comes from WS / refresh
      if (mounted) {
        setState(() {
          _optimisticValue = null;
          _toggling = false;
        });
        widget.onUpdate();
      }
    } catch (e) {
      // Revert on error
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
