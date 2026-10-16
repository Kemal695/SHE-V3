// =============================================================================
// SHE V3 — Gate control screen (design sheet screen 8)
// =============================================================================
// A dedicated Open / Close / Stop panel for a gate device.
//
// COMMAND CONTRACT (agreed 2026-10-08): this screen drives the device through
// the existing out-of-band command path — `NodeService.executeCommand(nodeId,
// 'gate_open' | 'gate_close' | 'gate_stop')` → POST /api/v3/nodes/{id}/commands
// → firmware (`params/remote`). The firmware must be taught to:
//   - handle the `gate_open` / `gate_close` / `gate_stop` cmd strings, and
//   - report the gate's position back as a node param named `state` with a
//     String value 'open' | 'closed' | 'stopped'.
// No backend change is needed — the command endpoint already exists.
//
// STATE READBACK reuses the SAME `nodeDeviceParamsProvider('$nodeId|$deviceId')`
// the dashboard and devices screens use, so "Current state" follows the board
// the same way a device's Power switch does. While a command is in flight we
// show the optimistic action; once the firmware reports `state` it becomes the
// authoritative value.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../l10n/app_localizations.dart';
import '../device_detail/device_detail_screen.dart' show nodeDeviceParamsProvider;
import '../device_detail/node_service.dart';

class GateControlScreen extends ConsumerStatefulWidget {
  const GateControlScreen({
    super.key,
    this.nodeId,
    this.deviceId,
    this.name,
    this.isOnline = false,
  });

  final String? nodeId;
  final String? deviceId;
  final String? name;
  final bool isOnline;

  @override
  ConsumerState<GateControlScreen> createState() => _GateControlScreenState();
}

class _GateControlScreenState extends ConsumerState<GateControlScreen> {
  String? _pending;
  bool _acting = false;

  Future<void> _send(String action) async {
    final l = AppLocalizations.of(context);
    final nodeId = widget.nodeId ?? '';
    if (nodeId.isEmpty) return;

    if (!widget.isOnline) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l?.gateOffline(widget.name ?? 'Gate') ?? 'Device is offline.',
          ),
          backgroundColor: V3Colors.surface2,
        ),
      );
      return;
    }

    setState(() => _acting = true);
    try {
      await ref
          .read(nodeServiceProvider)
          .executeCommand(nodeId, 'gate_$action');
      if (!mounted) return;
      // Optimistic: show the requested action until the board reports `state`.
      setState(() => _pending = action);
      final key = '$nodeId|${widget.deviceId ?? ''}';
      ref.invalidate(nodeDeviceParamsProvider(key));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l?.gateCommandQueued ?? 'Command sent'),
          backgroundColor: V3Colors.successAlt,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l?.gateCommandError(e.toString()) ?? 'Gate command failed: $e',
          ),
          backgroundColor: V3Colors.errorAlt,
        ),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  /// The board-reported gate position, or null if it hasn't reported yet.
  String? _stateFromParams(List<Map<String, dynamic>>? params) {
    if (params == null) return null;
    for (final p in params) {
      if (p['param_name'] == 'state') {
        final v = p['reported_value'] ?? p['last_value'];
        if (v is String) return v.toLowerCase();
        return null;
      }
    }
    return null;
  }

  /// What to display: the board's `state` when present, otherwise the optimistic
  /// pending action, otherwise 'idle'.
  String _displayState(List<Map<String, dynamic>>? params) {
    final s = _stateFromParams(params);
    if (s != null) return s;
    if (_pending != null) return _pending!;
    return 'idle';
  }

  (String label, Color tone) _map(String state) {
    final l = AppLocalizations.of(context);
    switch (state) {
      case 'open':
        return (l?.gateStatusOpen ?? 'Open', V3Colors.primary);
      case 'closed':
        return (l?.gateStatusClosed ?? 'Closed', V3Colors.dim);
      case 'stopped':
        return (l?.gateStatusStopped ?? 'Stopped', V3Colors.warningAlt);
      case 'idle':
        return (l?.gateStatusIdle ?? 'Idle', V3Colors.dim);
      case 'unknown':
        return (l?.gateStatusUnknown ?? 'Unknown', V3Colors.dim);
      default:
        // Transient optimistic values: open/close/stop (from _pending).
        if (state == 'close') {
          return (l?.gateStatusClosed ?? 'Closed', V3Colors.primary);
        }
        if (state == 'stop') {
          return (l?.gateStatusStopped ?? 'Stopped', V3Colors.warningAlt);
        }
        return (l?.gateStatusUnknown ?? 'Unknown', V3Colors.dim);
    }
  }

  String _activeAction(String state) {
    if (state == 'open') return 'open';
    if (state == 'closed') return 'close';
    if (state == 'stopped') return 'stop';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final nodeId = widget.nodeId ?? '';
    final deviceId = widget.deviceId ?? '';
    final paramsAsync = deviceId.isEmpty
        ? null
        : ref.watch(nodeDeviceParamsProvider('$nodeId|$deviceId'));
    final params = paramsAsync?.valueOrNull;

    final state = _displayState(params);
    final (stateLabel, stateTone) = _map(state);
    final active = _activeAction(state);
    final displayName = widget.name ?? l?.gateTitle ?? 'Gate';

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: Column(
          children: [
            SHEAppBar(
              title: l?.gateTitle ?? 'Gate control',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(V3Spacing.md),
                children: [
                  if (l?.gateSubtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: V3Spacing.md),
                      child: Text(
                        l!.gateSubtitle,
                        style: const TextStyle(
                          color: V3Colors.text2,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  SHECard(
                    child: Row(
                      children: [
                        DeviceIcon(
                          kind: 'gate',
                          on: state == 'open',
                          size: 44,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: V3Colors.ink,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  SHEStatusBadge(online: widget.isOnline),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: stateTone.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(
                                        V3Radius.sm,
                                      ),
                                    ),
                                    child: Text(
                                      stateLabel,
                                      style: TextStyle(
                                        color: stateTone,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: V3Spacing.lg),
                  SHESectionHeader(
                    title: l?.gateCurrentState ?? 'Current state',
                  ),
                  const SizedBox(height: V3Spacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: l?.gateOpen ?? 'Open',
                          icon: Icons.lock_open_outlined,
                          active: active == 'open',
                          loading: _acting && _pending == 'open',
                          enabled: widget.isOnline && !_acting,
                          onPressed: () => _send('open'),
                        ),
                      ),
                      const SizedBox(width: V3Spacing.sm),
                      Expanded(
                        child: _ActionButton(
                          label: l?.gateClose ?? 'Close',
                          icon: Icons.lock_outlined,
                          active: active == 'close',
                          loading: _acting && _pending == 'close',
                          enabled: widget.isOnline && !_acting,
                          onPressed: () => _send('close'),
                        ),
                      ),
                      const SizedBox(width: V3Spacing.sm),
                      Expanded(
                        child: _ActionButton(
                          label: l?.gateStop ?? 'Stop',
                          icon: Icons.stop_circle_outlined,
                          active: active == 'stop',
                          loading: _acting && _pending == 'stop',
                          enabled: widget.isOnline && !_acting,
                          onPressed: () => _send('stop'),
                        ),
                      ),
                    ],
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

/// One of the three Open / Close / Stop controls. `active` renders it filled
/// (primary); otherwise it is the secondary/ghost style so the current position
/// reads at a glance.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.loading,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool active;
  final bool loading;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SHEButton(
      label: label,
      icon: icon,
      variant: active ? SHEButtonVariant.primary : SHEButtonVariant.secondary,
      loading: loading,
      onPressed: enabled ? onPressed : null,
    );
  }
}
