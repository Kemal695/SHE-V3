// =============================================================================
// SHE V3 — Automations screen (list / create / edit / enable / run / delete)
// =============================================================================
// Backend: AutomationController (V3-API-SPECIFICATION §7).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error.dart';
import '../../core/theme/v3_design_tokens.dart';
import 'automation_editor.dart'
    show AutomationEditorDialog, AutomationEditorResult;
import 'automation_service.dart';

/// Automations for a home.
final homeAutomationsProvider =
    FutureProvider.family<List<Automation>, String>(
  (ref, homeId) => ref.read(automationServiceProvider).listAutomations(homeId),
);

class AutomationsScreen extends ConsumerStatefulWidget {
  final String homeId;

  const AutomationsScreen({super.key, required this.homeId});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(homeAutomationsProvider(widget.homeId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(apiErrorMessage(e)), backgroundColor: V3Colors.error),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fire(Automation a) async {
    final result = await ref.read(automationServiceProvider).trigger(a.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isFullSuccess
              ? '${a.name} ran · ${result.executed} action(s)'
              : '${a.name} partly ran · ${result.executed} ok, ${result.failed.length} failed',
        ),
        backgroundColor:
            result.isFullSuccess ? V3Colors.success : V3Colors.warning,
      ),
    );
  }

  Future<void> _confirmDelete(Automation a) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: V3Colors.surface,
            title: const Text('Delete automation?',
                style: TextStyle(color: V3Colors.textPrimary)),
            content: const Text('Deleting a rule does not change devices.',
                style: TextStyle(color: V3Colors.textSecondary)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete',
                    style: TextStyle(color: V3Colors.error)),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _run(() => ref.read(automationServiceProvider).deleteAutomation(a.id));
  }

  Future<void> _openEditor(Automation? existing) async {
    final result = await showDialog<AutomationEditorResult>(
      context: context,
      builder: (ctx) => AutomationEditorDialog(
        homeId: widget.homeId,
        existing: existing,
      ),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      final svc = ref.read(automationServiceProvider);
      if (existing == null) {
        await svc.createAutomation(
          widget.homeId,
          name: result.name,
          trigger: result.trigger,
          actions: result.actions,
        );
      } else {
        await svc.updateAutomation(existing.id, name: result.name);
      }
    });

    // A SCHEDULE rule deliberately does NOT touch the device when you save it —
    // it waits for its time. Without saying so, "I saved it and nothing happened"
    // looks like a bug. Spell out what will happen and how to test it now.
    if (!mounted) return;
    final isSchedule = result.trigger['type'] == 'SCHEDULE';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        backgroundColor: V3Colors.surface,
        content: Text(
          existing == null
              ? (isSchedule
                  ? 'Saved. It will run at its scheduled time — '
                      'tap ▶ on the card to test it right now.'
                  : 'Saved. Tap ▶ on the card to run it.')
              : 'Updated.',
          style: const TextStyle(color: V3Colors.textPrimary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(homeAutomationsProvider(widget.homeId));

    return Scaffold(
      backgroundColor: V3Colors.background,
      appBar: AppBar(
        backgroundColor: V3Colors.background,
        title: const Text('Automations',
            style: TextStyle(color: V3Colors.textPrimary)),
        iconTheme: const IconThemeData(color: V3Colors.textSecondary),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: V3Colors.primary,
        onPressed: _busy ? null : () => _openEditor(null),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: async.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: V3Colors.primary)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(V3Spacing.xl),
            child: Text('Could not load automations: $e',
                style: const TextStyle(color: V3Colors.textSecondary)),
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(V3Spacing.xl),
                child: Text(
                  'No automations yet.\nTap + to create one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: V3Colors.textSecondary),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final a = items[i];
              // Expandable card — collapsed shows name + trigger summary,
              // expanded reveals the toggle / Run-now / Delete row (hidden
              // by default per the user's request). Matches the scenes page
              // and the dashboard device cards visually.
              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: V3Spacing.md, vertical: V3Spacing.xs),
                child: Material(
                  color: V3Colors.surface,
                  borderRadius:
                      BorderRadius.circular(V3Radius.lg),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    iconColor: V3Colors.textSecondary,
                    collapsedIconColor: V3Colors.textSecondary,
                    tilePadding: const EdgeInsets.symmetric(
                        horizontal: V3Spacing.md),
                    leading: Icon(
                      a.enabled ? Icons.bolt : Icons.bolt_outlined,
                      color: a.enabled
                          ? V3Colors.primary
                          : V3Colors.textSecondary,
                    ),
                    title: Text(a.name,
                        style: const TextStyle(
                            color: V3Colors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(a.triggerLabel,
                        style: const TextStyle(
                            color: V3Colors.textSecondary, fontSize: 12)),
                    childrenPadding: const EdgeInsets.fromLTRB(
                        V3Spacing.md, 0, V3Spacing.sm, V3Spacing.sm),
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Switch(
                            value: a.enabled,
                            activeColor: V3Colors.primary,
                            onChanged: _busy
                                ? null
                                : (v) => _run(() => ref
                                    .read(automationServiceProvider)
                                    .setEnabled(a.id, v)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.play_arrow,
                                color: V3Colors.success),
                            tooltip: 'Run now',
                            onPressed:
                                _busy ? null : () => _fire(a),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: V3Colors.error),
                            tooltip: 'Delete',
                            onPressed: _busy
                                ? null
                                : () => _confirmDelete(a),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}