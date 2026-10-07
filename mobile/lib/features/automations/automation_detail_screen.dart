// =============================================================================
// SHE V3 — Automation detail (design sheet panel 2)
// =============================================================================
// Hero (icon + name + Enabled badge) · WHEN card · THEN card · Recent runs with
// a Run now button · Edit / Duplicate / Delete.
//
// This is the hub the list links into: the card in the list is now a summary,
// and everything you can DO with an automation lives here.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../scenes/scene_service.dart' show homeDevicesProvider;
import 'automation_service.dart';
import 'automation_wizard.dart' show AutomationWizardPage;

class AutomationDetailScreen extends ConsumerStatefulWidget {
  final String homeId;
  final Automation automation;

  const AutomationDetailScreen({
    super.key,
    required this.homeId,
    required this.automation,
  });

  @override
  ConsumerState<AutomationDetailScreen> createState() =>
      _AutomationDetailScreenState();
}

class _AutomationDetailScreenState
    extends ConsumerState<AutomationDetailScreen> {
  late Automation _a;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _a = widget.automation;
  }

  /// Resolve the LIVE user-facing name of a device referenced by a config.
  String _deviceLabel(Map<String, dynamic> c) {
    final id = c['node_device_id']?.toString();
    if (id != null && id.isNotEmpty) {
      final devices = ref.read(homeDevicesProvider(widget.homeId)).valueOrNull;
      if (devices != null) {
        for (final d in devices) {
          if (d.deviceId == id) return d.shownName;
        }
      }
    }
    return c['device_name']?.toString() ?? 'Device';
  }

  String get _whenLabel {
    final t = _a.trigger;
    switch (t['type']?.toString()) {
      // SOLAR is a distinct trigger type on the backend (the sunrise/sunset time
      // moves through the year, so a fixed cron would drift). It was falling to
      // the default branch and being described as a manual trigger.
      case 'SOLAR':
        final event = (t['event'] ?? 'sunrise').toString().toLowerCase();
        return 'At ${event == 'sunset' ? 'sunset' : 'sunrise'}, every day';
      case 'SCHEDULE':
        final cron = (t['cron'] ?? '').toString().split(RegExp(r'\s+'));
        if (cron.length == 5) {
          final h = cron[1].padLeft(2, '0');
          final m = cron[0].padLeft(2, '0');
          final day = switch (cron[4]) {
            '1-5' => 'on weekdays',
            '0,6' => 'on weekends',
            _ => 'every day',
          };
          return 'At $h:$m, $day';
        }
        return 'On a schedule';
      case 'NODE_STATE':
        return 'When ${_deviceLabel(t)} turns '
            '${t['value'] == true ? 'ON' : 'OFF'}';
      default:
        return 'When you tap Run now';
    }
  }

  String get _thenLabel {
    if (_a.rules.isEmpty) return 'Do nothing';
    final parts = <String>[];
    for (final r in _a.rules) {
      final c = r.config;
      if (r.type == 'WRITE_PARAM') {
        final on = (c['params'] as Map?)?['Power'] == true;
        parts.add('${_deviceLabel(c)} → ${on ? 'ON' : 'OFF'}');
      } else if (r.type == 'ACTIVATE_SCENE') {
        parts.add('Activate scene');
      } else {
        parts.add(r.type);
      }
    }
    return parts.join('\n');
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: V3Colors.errorAlt,
          content: Text(apiErrorMessage(e)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    final list = await ref
        .read(automationServiceProvider)
        .listAutomations(widget.homeId);
    if (!mounted) return;
    final fresh = list.where((x) => x.id == _a.id).firstOrNull;
    if (fresh != null) setState(() => _a = fresh);
  }

  Future<void> _runNow() async {
    await _run(() async {
      final res = await ref.read(automationServiceProvider).trigger(_a.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: V3Colors.surface,
          content: Text(
            res.isFullSuccess
                ? 'Ran ${res.executed} action(s).'
                : 'Ran ${res.executed}, failed: ${res.failed.join(', ')}',
            style: const TextStyle(color: V3Colors.textPrimary),
          ),
        ),
      );
      await _reload();
    });
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AutomationWizardPage(
          homeId: widget.homeId,
          existing: _a,
        ),
      ),
    );
    if (saved != true || !mounted) return;

    // 🔴 REQUIRED (bugfix 2026-10-08). Saving only refreshed THIS screen's copy.
    // The list renders from `homeAutomationsProvider` and was never told, so
    // going back showed the old name / trigger / actions — the edit appeared to
    // have done nothing at all ("I can't edit from inside the card").
    //
    // The list route stays mounted underneath this one, so invalidating the
    // shared provider makes it refetch and it is already up to date by the time
    // the user navigates back. No pop value needed.
    ref.invalidate(homeAutomationsProvider(widget.homeId));

    // Re-read our own copy so the WHEN / THEN cards show the new values.
    await _reload();
  }

  /// Copy this rule under a new name (design sheet: "Duplicate").
  Future<void> _duplicate() async {
    await _run(() async {
      final svc = ref.read(automationServiceProvider);
      await svc.createAutomation(
        widget.homeId,
        name: '${_a.name} (copy)',
        trigger: Map<String, Object>.from(_a.trigger),
        actions: _a.rules
            .where((r) => r.type == 'WRITE_PARAM')
            .map((r) => AutomationActionDraft(
                  nodeId: r.config['node_id']?.toString() ?? '',
                  deviceName: r.config['device_name']?.toString() ?? '',
                  nodeDeviceId: r.config['node_device_id']?.toString() ?? '',
                  params: {
                    'Power': (r.config['params'] as Map?)?['Power'] == true,
                  },
                ))
            .toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Duplicated.')),
      );
      Navigator.of(context).pop(true);
    });
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: V3Colors.surface,
            title: const Text('Delete automation?',
                style: TextStyle(color: V3Colors.ink)),
            content: Text('"${_a.name}" will stop running.',
                style: const TextStyle(color: V3Colors.text2)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete',
                    style: TextStyle(color: V3Colors.errorAlt)),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _run(() async {
      await ref.read(automationServiceProvider).deleteAutomation(_a.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              V3Spacing.md, 0, V3Spacing.md, V3Spacing.xxl),
          children: [
            SHEAppBar(
              title: _a.name,
              subtitle: 'Automation',
              onBack: () => Navigator.of(context).pop(),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                icon: const Icon(Icons.more_vert, color: V3Colors.dim),
                color: V3Colors.surface2,
                onSelected: (v) {
                  if (v == 'edit') _edit();
                  if (v == 'duplicate') _duplicate();
                  if (v == 'run') _runNow();
                  if (v == 'delete') _delete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(
                      value: 'duplicate', child: Text('Duplicate')),
                  const PopupMenuItem(value: 'run', child: Text('Run now')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
            const SizedBox(height: V3Spacing.sm),
            _hero(),
            const SizedBox(height: V3Spacing.md),
            _card(
              icon: Icons.bolt,
              label: 'WHEN',
              value: _whenLabel,
            ),
            const SizedBox(height: V3Spacing.sm),
            _card(
              icon: Icons.play_circle_outline,
              label: 'THEN',
              value: _thenLabel,
            ),
            const SizedBox(height: V3Spacing.md),
            _recentRuns(),
            const SizedBox(height: V3Spacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _edit,
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: V3Colors.text2,
                      side: const BorderSide(color: V3Colors.border),
                      // Same reasoning as app.dart: a local styleFrom overrides
                      // the disabled colours, so without this a disabled button
                      // (e.g. while _busy) looks perfectly tappable.
                      disabledForegroundColor:
                          V3Colors.text2.withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(V3Radius.lg)),
                    ),
                  ),
                ),
                const SizedBox(width: V3Spacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _duplicate,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Duplicate'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: V3Colors.text2,
                      side: const BorderSide(color: V3Colors.border),
                      // Same reasoning as app.dart: a local styleFrom overrides
                      // the disabled colours, so without this a disabled button
                      // (e.g. while _busy) looks perfectly tappable.
                      disabledForegroundColor:
                          V3Colors.text2.withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(V3Radius.lg)),
                    ),
                  ),
                ),
                const SizedBox(width: V3Spacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: V3Colors.errorAlt,
                      side: BorderSide(
                          color: V3Colors.errorAlt.withValues(alpha: 0.4)),
                      disabledForegroundColor:
                          V3Colors.errorAlt.withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(V3Radius.lg)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero() {
    final on = _a.enabled;
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: on
                  ? V3Colors.primary.withValues(alpha: 0.15)
                  : V3Colors.fill,
              borderRadius: BorderRadius.circular(V3Radius.md),
            ),
            child: Icon(
              _a.isSolar
                  ? Icons.wb_twilight
                  : _a.triggerType == AutomationTriggerType.schedule
                      ? Icons.schedule
                      : _a.triggerType == AutomationTriggerType.nodeState
                          ? Icons.sensors
                          : Icons.touch_app,
              size: 22,
              color: on ? V3Colors.primary : V3Colors.dim,
            ),
          ),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_a.name,
                    style: const TextStyle(
                        color: V3Colors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: on
                        ? V3Colors.successAlt.withValues(alpha: 0.15)
                        : V3Colors.fill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(on ? 'Enabled' : 'Disabled',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: on ? V3Colors.successAlt : V3Colors.dim)),
                ),
              ],
            ),
          ),
          SHEToggle(
            value: on,
            enabled: !_busy,
            onChanged: (v) => _run(() async {
              await ref.read(automationServiceProvider).setEnabled(_a.id, v);
              // Same staleness fix as _edit(): the list would otherwise keep
              // showing the old Enabled/Disabled state after you go back.
              ref.invalidate(homeAutomationsProvider(widget.homeId));
              await _reload();
            }),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: V3Colors.primary),
          const SizedBox(width: V3Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: V3Colors.dim,
                        fontSize: 10.5,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(value,
                    style: const TextStyle(
                        color: V3Colors.ink, fontSize: 13.5, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentRuns() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Recent runs',
              style: TextStyle(
                  color: V3Colors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: V3Spacing.sm),
          Row(
            children: [
              Icon(
                _a.lastFiredAt == null
                    ? Icons.history
                    : Icons.check_circle_outline,
                size: 16,
                color: _a.lastFiredAt == null
                    ? V3Colors.dim
                    : V3Colors.successAlt,
              ),
              const SizedBox(width: 6),
              Text(
                _a.lastFiredAt == null
                    ? 'Never run yet'
                    : 'Last run: ${_a.lastRunLabel}',
                style: const TextStyle(color: V3Colors.text2, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: V3Spacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _runNow,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: V3Colors.night))
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_busy ? 'Running…' : 'Run now'),
              style: ElevatedButton.styleFrom(
                backgroundColor: V3Colors.primary,
                foregroundColor: V3Colors.night,
                // See app.dart: a local backgroundColor also overrides the
                // disabled colours, so a disabled button would still look live.
                disabledBackgroundColor:
                    V3Colors.primary.withValues(alpha: 0.18),
                disabledForegroundColor: V3Colors.dim,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(V3Radius.lg)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
