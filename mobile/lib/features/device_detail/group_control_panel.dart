// =============================================================================
// SHE V3 — Group / master control panel (ADR-015)
// =============================================================================
// Lights / Sockets / All as a single atomic intent (group_set), NOT a loop of
// per-channel writes. On the 24-relay board the lights are channels 0-7 and
// 16-23 with sockets in between, so "all lights off" sent as "every channel
// off" would also kill the sockets. The device applies the group mask itself.
//
// Only shown when the node has enough channels for the groups to mean anything;
// on a 4-channel direct-GPIO board "lights" and "sockets" do not exist.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import 'node_service.dart';

class GroupControlPanel extends ConsumerStatefulWidget {
  final String nodeId;

  /// Advertised SKU ("SHE-R4" | "SHE-R8" | "SHE-R16" | "SHE-R24").
  final String sku;

  /// Fired after a successful group intent. The parent uses it to refresh the
  /// per-device toggles — a group_set changes 8/16/24 channels at once, and
  /// without this the individual switches kept their stale state.
  final VoidCallback? onChanged;

  const GroupControlPanel({
    super.key,
    required this.nodeId,
    required this.sku,
    this.onChanged,
  });

  @override
  ConsumerState<GroupControlPanel> createState() => _GroupControlPanelState();
}

class _GroupControlPanelState extends ConsumerState<GroupControlPanel> {
  // Which group button is mid-flight — blocks double-taps and drives the spinner.
  String? _busy;

  /// The channel map that makes group intents meaningful is the 24-relay layout.
  /// R8/R16 have a contiguous lights block, so the intents still work; R4 has no
  /// sockets and no meaningful split, so the panel is hidden for it.
  bool get _supported => widget.sku != 'SHE-R4';

  Future<void> _apply(String group, bool on) async {
    if (_busy != null) return;
    setState(() => _busy = '$group:$on');
    try {
      await ref.read(nodeServiceProvider).setGroup(widget.nodeId, group, on);
      // Refresh the per-device toggles: one group_set moved many channels.
      widget.onChanged?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_label(group)} turned ${on ? 'on' : 'off'}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: V3Colors.error,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _label(String g) => switch (g) {
        'lights' => 'Lights',
        'sockets' => 'Sockets',
        _ => 'All',
      };

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'MASTER CONTROL',
          style:  TextStyle(
            color: V3Colors.textSecondary,
            fontSize: V3Typography.overlineSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.md),
            child: Column(
              children: [
                _row(context, 'all'),
                const Divider(height: V3Spacing.lg),
                _row(context, 'lights'),
                const Divider(height: V3Spacing.lg),
                _row(context, 'sockets'),
              ],
            ),
          ),
        ),
        const SizedBox(height: V3Spacing.md),
      ],
    );
  }

  Widget _row(BuildContext context, String group) {
    return Row(
      children: [
        Icon(_icon(group), size: 20, color: V3Colors.textSecondary),
        const SizedBox(width: V3Spacing.md),
        Expanded(
          child:
              Text(_label(group), style: Theme.of(context).textTheme.bodyLarge),
        ),
        _actionButton(group, true, 'On'),
        const SizedBox(width: V3Spacing.sm),
        _actionButton(group, false, 'Off'),
      ],
    );
  }

  Widget _actionButton(String group, bool on, String text) {
    final key = '$group:$on';
    final isBusy = _busy == key;
    final disabled = _busy != null && !isBusy;

    return SizedBox(
      height: 34,
      child: OutlinedButton(
        onPressed: disabled ? null : () => _apply(group, on),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
          foregroundColor: on ? V3Colors.success : V3Colors.error,
          side: BorderSide(
            color: (on ? V3Colors.success : V3Colors.error)
                .withValues(alpha: disabled ? 0.3 : 0.6),
          ),
        ),
        child: isBusy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(text,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }

  IconData _icon(String group) => switch (group) {
        'lights' => Icons.lightbulb_outline,
        'sockets' => Icons.power_outlined,
        _ => Icons.home_outlined,
      };
}
