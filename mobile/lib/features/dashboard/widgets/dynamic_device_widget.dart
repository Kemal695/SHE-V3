// =============================================================================
// SHE V3 — Dynamic Device Widget (type-based rendering)
// =============================================================================
// V3-MOBILE-APP §5.4. Switch on device.type → render appropriate card.
// GenericDeviceCard fallback renders params as toggles/sliders.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/v3_design_tokens.dart';
import '../../../core/widgets/she_toggle.dart';
import '../../../core/widgets/haptic_slider.dart';
import 'radial_quick_actions.dart' show RadialAction, showRadialQuickActions;

class DynamicDeviceWidget extends StatelessWidget {
  final Map<String, dynamic> node;
  final List<Map<String, dynamic>>? devices;
  final Function(String deviceId, String paramName, dynamic value)? onParamWrite;

  const DynamicDeviceWidget({
    super.key,
    required this.node,
    this.devices,
    this.onParamWrite,
  });

  @override
  Widget build(BuildContext context) {
    final isOnline = node['is_online'] ?? false;
    final name = node['name'] ?? node['node_id'] ?? 'Unknown';
    final sku = node['sku'] ?? 'SHE-R8';

    // V3-DESIGN-SYSTEM §1.10 — long-press opens the radial quick-action menu on
    // EVERY device card, whichever typed renderer the switch below picks. Wrapping
    // the result (rather than editing all five renderers) keeps this in one place.
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPressStart: (d) => _showQuickActions(context, d.globalPosition),
      child: _buildCard(context, isOnline, name, sku),
    );
  }

  /// V3-DESIGN-SYSTEM §1.10 — radial quick actions on long-press.
  void _showQuickActions(BuildContext context, Offset position) {
    final nodeId = node['id']?.toString() ?? '';
    final isOnline = node['is_online'] ?? false;

    // Find the first switch-type device so "On / Off" can be offered.
    Map<String, dynamic>? switchDevice;
    for (final d in devices ?? const <Map<String, dynamic>>[]) {
      if ((d['device_type'] as String? ?? '') == 'esp.device.switch') {
        switchDevice = d;
        break;
      }
    }

    final actions = <RadialAction>[
      RadialAction(
        icon: Icons.settings_outlined,
        label: 'Settings',
        onPressed: () => context.push('/node/$nodeId'),
      ),
      RadialAction(
        icon: Icons.show_chart,
        label: 'Energy',
        onPressed: () => context.push('/node/$nodeId/energy'),
      ),
      if (switchDevice != null) ...[
        RadialAction(
          icon: Icons.power_settings_new,
          label: 'On',
          color: V3Colors.success,
          onPressed: () => _writeSwitch(switchDevice!, true),
        ),
        RadialAction(
          icon: Icons.power_off,
          label: 'Off',
          color: V3Colors.error,
          onPressed: () => _writeSwitch(switchDevice!, false),
        ),
      ],
    ];

    showRadialQuickActions(
      context: context,
      position: position,
      actions: actions,
      // A little wider when there are four actions so they don't crowd.
      radius: actions.length >= 4 ? 110 : 96,
    );
  }

  void _writeSwitch(Map<String, dynamic> device, bool value) {
    final deviceId = device['id']?.toString();
    if (deviceId == null) return;
    onParamWrite?.call(deviceId, 'Power', value);
  }

  Widget _buildCard(
      BuildContext context, bool isOnline, String name, String sku) {
    // If devices list is provided, render the first controllable device
    if (devices != null && devices!.isNotEmpty) {
      final device = devices!.first;
      final deviceType = device['device_type'] as String? ?? '';

      return switch (deviceType) {
        'esp.device.switch' => SwitchDeviceCard(
            node: node, device: device, isOnline: isOnline, onParamWrite: onParamWrite),
        'esp.device.lightbulb' => LightbulbDeviceCard(
            node: node, device: device, isOnline: isOnline, onParamWrite: onParamWrite),
        'esp.device.fan' => FanDeviceCard(
            node: node, device: device, isOnline: isOnline, onParamWrite: onParamWrite),
        'esp.device.temp_sensor' => TempSensorCard(
            node: node, device: device, isOnline: isOnline),
        'esp.device.energy_meter' => EnergyMeterCard(
            node: node, device: device, isOnline: isOnline),
        _ => GenericDeviceCard(
            node: node, device: device, isOnline: isOnline, onParamWrite: onParamWrite),
      };
    }

    // Fallback: node-level card
    return _NodeCard(
      name: name,
      sku: sku,
      isOnline: isOnline,
      onTap: () => context.push('/node/${node['id']}'),
    );
  }
}

// ─── Switch device card (esp.device.switch) ────────────────────────────────
class SwitchDeviceCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;
  final Function(String, String, dynamic)? onParamWrite;

  const SwitchDeviceCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
    this.onParamWrite,
  });

  @override
  Widget build(BuildContext context) {
    final name = device['display_name'] ?? device['device_name'] ?? 'Switch';
    final params = device['params'] as List<dynamic>? ?? [];
    final powerParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Power',
      orElse: () => null,
    );
    final isOn = powerParam?['last_value'] == true;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(V3Radius.lg),
        onTap: () => context.push('/node/${node['id']}'),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            boxShadow: V3Colors.activeGlow(isOn: isOn && isOnline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    isOn ? Icons.power : Icons.power_off,
                    size: 32,
                    color: isOn && isOnline ? V3Colors.primary : V3Colors.textSecondary,
                  ),
                  // Online/offline badge
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? V3Colors.success : V3Colors.error,
                    ),
                  ),
                ],
              ),
              Text(name, style:  TextStyle(
                color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize,
                fontWeight: FontWeight.w600,
              ), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (powerParam != null && onParamWrite != null)
                SHEToggle(
                  value: isOn,
                  onChanged: (v) => onParamWrite!(device['id'], 'Power', v),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Lightbulb device card (esp.device.lightbulb — toggle + brightness slider) ────
class LightbulbDeviceCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;
  final Function(String, String, dynamic)? onParamWrite;

  const LightbulbDeviceCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
    this.onParamWrite,
  });

  @override
  Widget build(BuildContext context) {
    final name = device['display_name'] ?? device['device_name'] ?? 'Light';
    final params = device['params'] as List<dynamic>? ?? [];
    final powerParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Power', orElse: () => null);
    final brightnessParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Brightness', orElse: () => null);

    final isOn = powerParam?['last_value'] == true;
    final brightness = (brightnessParam?['last_value'] as num?)?.toDouble() ?? 0;

    return Card(
      child: InkWell(
        onTap: () => context.push('/node/${node['id']}'),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            boxShadow: V3Colors.activeGlow(isOn: isOn && isOnline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(Icons.lightbulb, size: 32,
                    color: isOn && isOnline ? V3Colors.warning : V3Colors.textSecondary),
                  if (powerParam != null && onParamWrite != null)
                    SHEToggle(value: isOn,
                      onChanged: (v) => onParamWrite!(device['id'], 'Power', v)),
                ],
              ),
              Text(name, style:  TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600)),
              if (brightnessParam != null && isOn && onParamWrite != null)
                Padding(
                  padding: const EdgeInsets.only(top: V3Spacing.sm),
                  child: HapticSlider(
                    value: brightness,
                    min: 0, max: 100,
                    snapIncrement: 1.0,
                    label: 'Brightness',
                    onChanged: (v) => onParamWrite!(device['id'], 'Brightness', v),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Fan device card (esp.device.fan — toggle + speed slider 1-5) ────────────
class FanDeviceCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;
  final Function(String, String, dynamic)? onParamWrite;

  const FanDeviceCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
    this.onParamWrite,
  });

  @override
  Widget build(BuildContext context) {
    final name = device['display_name'] ?? device['device_name'] ?? 'Fan';
    final params = device['params'] as List<dynamic>? ?? [];
    final powerParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Power', orElse: () => null);
    final speedParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Speed', orElse: () => null);

    final isOn = powerParam?['last_value'] == true;
    final speed = (speedParam?['last_value'] as num?)?.toInt() ?? 1;

    return Card(
      child: InkWell(
        onTap: () => context.push('/node/${node['id']}'),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            boxShadow: V3Colors.activeGlow(isOn: isOn && isOnline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Fan icon rotates when ON (V3-DESIGN-SYSTEM §1.10)
                  isOn
                    ? _RotatingFanIcon(speed: speed)
                    :  Icon(Icons.mode_fan_off, size: 32, color: V3Colors.textSecondary),
                  if (powerParam != null && onParamWrite != null)
                    SHEToggle(value: isOn,
                      onChanged: (v) => onParamWrite!(device['id'], 'Power', v)),
                ],
              ),
              Text(name, style:  TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600)),
              if (speedParam != null && isOn && onParamWrite != null)
                Padding(
                  padding: const EdgeInsets.only(top: V3Spacing.sm),
                  child: HapticSlider(
                    value: speed.toDouble(),
                    min: 1, max: 5,
                    snapIncrement: 1.0,
                    label: 'Speed',
                    onChanged: (v) => onParamWrite!(device['id'], 'Speed', v.toInt()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Temperature sensor card (read-only) ────────────────────────────────────
class TempSensorCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;

  const TempSensorCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final name = device['display_name'] ?? device['device_name'] ?? 'Sensor';
    final params = device['params'] as List<dynamic>? ?? [];
    final tempParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Temperature', orElse: () => null);
    final temp = (tempParam?['last_value'] as num?)?.toDouble() ?? 0;

    return Card(
      child: InkWell(
        onTap: () => context.push('/node/${node['id']}'),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.thermostat, size: 32,
                color: isOnline ? V3Colors.primary : V3Colors.textSecondary),
              Text(name, style:  TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600)),
              Text('${temp.toStringAsFixed(1)}°C', style:  TextStyle(
                color: V3Colors.primary, fontSize: V3Typography.displaySize,
                fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Energy meter card (read-only + chart link) ─────────────────────────────
class EnergyMeterCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;

  const EnergyMeterCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    final params = device['params'] as List<dynamic>? ?? [];
    final powerParam = params.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['param_name'] == 'Power_Consumption' || p?['param_name'] == 'Power',
      orElse: () => null);
    final power = (powerParam?['last_value'] as num?)?.toDouble() ?? 0;

    return Card(
      child: InkWell(
        onTap: () => context.push('/node/${node['id']}/energy'),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            boxShadow: V3Colors.activeGlow(isOn: power > 0 && isOnline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.bolt, size: 32,
                color: power > 0 && isOnline ? V3Colors.warning : V3Colors.textSecondary),
               Text('Energy', style: TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600)),
              Text('${power.toStringAsFixed(1)} W', style:  TextStyle(
                color: V3Colors.primary, fontSize: V3Typography.displaySize,
                fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Generic device card (fallback — renders params dynamically) ───────────
class GenericDeviceCard extends StatelessWidget {
  final Map<String, dynamic> node;
  final Map<String, dynamic> device;
  final bool isOnline;
  final Function(String, String, dynamic)? onParamWrite;

  const GenericDeviceCard({
    super.key,
    required this.node,
    required this.device,
    required this.isOnline,
    this.onParamWrite,
  });

  @override
  Widget build(BuildContext context) {
    final name = device['display_name'] ?? device['device_name'] ?? 'Device';
    final params = device['params'] as List<dynamic>? ?? [];

    return Card(
      child: InkWell(
        onTap: () => context.push('/node/${node['id']}'),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.device_unknown, size: 32,
                color: isOnline ? V3Colors.primary : V3Colors.textSecondary),
              Text(name, style:  TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600)),
              ...params.cast<Map<String, dynamic>?>().map((p) {
                if (p == null) return const SizedBox.shrink();
                final paramName = p['param_name'] as String? ?? '';
                final dataType = p['data_type'] as String? ?? 'string';
                final value = p['last_value'];

                if (dataType == 'bool') {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(paramName, style:  TextStyle(color: V3Colors.textSecondary)),
                      if (onParamWrite != null)
                        SHEToggle(value: value == true,
                          onChanged: (v) => onParamWrite!(device['id'], paramName, v)),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(top: V3Spacing.xs),
                  child: Text('$paramName: $value', style:  TextStyle(
                    color: V3Colors.textSecondary, fontSize: V3Typography.captionSize)),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Node-level card (when no devices listed) ──────────────────────────────
class _NodeCard extends StatelessWidget {
  final String name;
  final String sku;
  final bool isOnline;
  final VoidCallback onTap;

  final VoidCallback? onLongPress;

  const _NodeCard({required this.name, required this.sku, required this.isOnline, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(V3Radius.lg),
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(V3Radius.lg),
            boxShadow: V3Colors.activeGlow(isOn: isOnline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(_iconForSku(sku), size: 32,
                    color: isOnline ? V3Colors.primary : V3Colors.textSecondary),
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isOnline ? V3Colors.success : V3Colors.textSecondary,
                    ),
                  ),
                ],
              ),
              Text(name, style:  TextStyle(color: V3Colors.textPrimary,
                fontSize: V3Typography.titleSize, fontWeight: FontWeight.w600),
                maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(sku, style:  TextStyle(color: V3Colors.textSecondary,
                fontSize: V3Typography.captionSize)),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForSku(String sku) => switch (sku) {
    'SHE-R4' => Icons.power,
    'SHE-R8' => Icons.dashboard,
    'SHE-R16' => Icons.developer_board,
    _ => Icons.device_unknown,
  };
}

// ─── Rotating fan icon (V3-DESIGN-SYSTEM §1.10 — "Fan blades rotate") ──────
class _RotatingFanIcon extends StatefulWidget {
  final int speed;  // 1-5

  const _RotatingFanIcon({required this.speed});

  @override
  State<_RotatingFanIcon> createState() => _RotatingFanIconState();
}

class _RotatingFanIconState extends State<_RotatingFanIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: Duration(milliseconds: 2000 ~/ widget.speed),  // speed 1=2s, 5=400ms
      vsync: this,
    )..repeat();
  }

  @override
  void didUpdateWidget(_RotatingFanIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.speed != oldWidget.speed) {
      _controller.duration = Duration(milliseconds: 2000 ~/ widget.speed);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      // Flutter 3.44 has no Icons.mode_fan (only Icons.mode_fan_off). This icon
      // is animated by a RotationTransition, so the replacement needs rotational
      // symmetry to read as a spinning fan — Icons.toys is a pinwheel and spins
      // cleanly, whereas Icons.air (wavy lines) looks wrong under rotation.
      child:  Icon(Icons.toys, size: 32, color: V3Colors.primary),
    );
  }
}
