// =============================================================================
// SHE V3 — Automations screen (list / create / edit / enable / run / delete)
// =============================================================================
// Backend: AutomationController (V3-API-SPECIFICATION §7).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/active_home.dart';
import '../../core/network/api_error.dart';
import '../../core/network/ws_client.dart' show wsConnectedProvider;
import '../../core/offline/offline_automations.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../device_detail/node_service.dart' show nodeServiceProvider;
import '../scenes/scene_service.dart' show homeDevicesProvider;
import 'automation_detail_screen.dart' show AutomationDetailScreen;
import 'automation_service.dart';
import 'automation_wizard.dart' show AutomationWizardPage;

// NOTE: `homeAutomationsProvider` moved to automation_service.dart so the detail
// screen can invalidate it too. It is re-exported implicitly through the
// `automation_service.dart` import above — see that file for why.

class AutomationsScreen extends ConsumerStatefulWidget {
  final String homeId;

  const AutomationsScreen({super.key, required this.homeId});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  bool _busy = false;

  /// Design-sheet filter chips: All | Scheduled | Device | Energy.
  String _filter = 'All';

  /// The home the API calls use.
  ///
  /// 🔴 This used to be `widget.homeId` straight through, and the router feeds
  /// that from `state.uri.queryParameters['homeId']` — a parameter nothing ever
  /// sets. So it was always the empty string, the request went out as
  /// `/api/v3/homes//automations`, Spring collapsed the double slash and bound
  /// `{homeId}` to the literal text `"automations"`. The backend then threw
  /// `Invalid UUID string: automations` -> HTTP 500, and the screen showed
  /// "Could not load automations". That is the whole "automation is not
  /// working" report: the list could never load at all.
  ///
  /// Resolved here the same way `_DevicesScreenState` does it — seed the id the
  /// backend uses, then ask the server for the real one.
  static const _defaultHomeId = '00000000-0000-0000-0000-000000000001';

  late String _homeId;

  @override
  void initState() {
    super.initState();
    final initial = widget.homeId;
    _homeId = initial.isNotEmpty ? initial : _defaultHomeId;
    if (initial.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveHome());
    }
  }

  Future<void> _resolveHome() async {
    // Picks the home that actually HAS nodes. `homes.first` was arbitrary — this
    // tenant has 32 homes named "My Home", and landing on an empty one is exactly
    // why the list read "0/0 enabled · No automations yet" while the real home
    // held five. See core/network/active_home.dart.
    final id = await resolveActiveHomeId(ref);
    if (id != null && mounted && id != _homeId) {
      setState(() => _homeId = id);
    }
  }

  /// Clear a cached failure — and re-resolve the home if we are still holding the
  /// placeholder, which yields an EMPTY (not failed) list and so never self-heals.
  void _retry() {
    if (_homeId == _defaultHomeId) _resolveHome();
    ref.invalidate(homeAutomationsProvider(_homeId));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(homeAutomationsProvider(_homeId));
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

  /// Copy an automation under a new name (design sheet: "Duplicate").
  Future<void> _duplicate(Automation a) async {
    await _run(() async {
      // Routed through the offline service: with no link a single-action schedule
      // is stored on the device instead of failing (see OfflineAutomationService).
      final res = await ref.read(offlineAutomationServiceProvider).create(
            homeId: _homeId,
            name: '${a.name} (copy)',
            trigger: Map<String, Object>.from(a.trigger),
            actions: a.rules
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
      final stored = res.outcome == AutomationSaveOutcome.cloud ||
          res.outcome == AutomationSaveOutcome.device;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.outcome == AutomationSaveOutcome.cloud
              ? 'Duplicated.'
              : res.message),
          duration: const Duration(seconds: 6),
        ),
      );
      if (stored) ref.invalidate(homeAutomationsProvider(_homeId));
    });
  }

  Future<void> _openDetail(Automation a) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AutomationDetailScreen(homeId: _homeId, automation: a),
      ),
    );
    if (changed == true) {
      ref.invalidate(homeAutomationsProvider(_homeId));
    }
  }

  Future<void> _openEditor(Automation? existing) async {
    // The 3-step wizard (When → If → Then) replaces the old single dialog. It
    // saves internally and pops `true`.
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AutomationWizardPage(
          homeId: _homeId,
          existing: existing,
        ),
      ),
    );
    if (saved != true || !mounted) return;
    await _run(() async {
      ref.invalidate(homeAutomationsProvider(_homeId));
    });

    // A SCHEDULE rule deliberately does NOT touch the device when you save it —
    // it waits for its time. Without saying so, "I saved it and nothing happened"
    // looks like a bug. Spell out what will happen and how to test it now.
    if (!mounted) return;
    final isSchedule =
        (existing?.triggerType ?? AutomationTriggerType.schedule) ==
            AutomationTriggerType.schedule;
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
    final async = ref.watch(homeAutomationsProvider(_homeId));
    // Warm the device list so `_deviceLabel` can resolve a device's CURRENT
    // (possibly renamed) display name synchronously.
    ref.watch(homeDevicesProvider(_homeId));

    // A provider failure is CACHED, so it does not clear itself when the link
    // returns. Heal the tab rather than leaving it stuck on the error card.
    ref.listen(wsConnectedProvider, (prev, next) {
      if (next && prev != true) _retry();
    });

    // An EMPTY list while still on the placeholder home id is not the truth — it
    // is the wrong home (see _resolveHome). Re-resolve once the data lands, so a
    // launch that happened to pick an empty home heals itself.
    if (_homeId == _defaultHomeId) {
      final items = async.valueOrNull;
      if (items != null && items.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _resolveHome();
        });
      }
    }

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: async.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: V3Colors.primary)),
          error: (e, _) => RefreshIndicator(
            color: V3Colors.primary,
            backgroundColor: V3Colors.surface,
            onRefresh: () =>
                ref.refresh(homeAutomationsProvider(_homeId).future),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                  V3Spacing.md, 0, V3Spacing.md, V3Spacing.xxl),
              children: [
                const SHEAppBar(title: 'Automation'),
                const SizedBox(height: V3Spacing.md),
                // KEEP the create affordance. With the cloud down a single-action
                // schedule can still be stored on the DEVICE, so replacing the
                // whole body with an error message made "create an automation
                // offline" impossible — which is exactly what was reported.
                _createPill(),
                const SizedBox(height: V3Spacing.md),
                SHEEmptyState(
                  icon: Icons.cloud_off,
                  tone: V3Colors.warningAlt,
                  title: 'Cannot reach SHE cloud',
                  body: apiErrorMessage(e),
                  actionLabel: 'Retry',
                  onAction: _retry,
                ),
              ],
            ),
          ),
          data: (items) {
            final enabledN = items.where((a) => a.enabled).length;
            return RefreshIndicator(
              color: V3Colors.primary,
              backgroundColor: V3Colors.surface,
              onRefresh: () =>
                  ref.refresh(homeAutomationsProvider(_homeId).future),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                    V3Spacing.md, 0, V3Spacing.md, V3Spacing.xxl),
                children: [
                  // No (+) in the app bar — the "Create Automation" pill below
                  // is the single create affordance (design sheet panel 1).
                  SHEAppBar(
                    title: 'Automation',
                    subtitle: '${enabledN}/${items.length} enabled',
                  ),
                  const SizedBox(height: V3Spacing.md),
                  _createPill(),
                  const SizedBox(height: V3Spacing.md),
                  _filterChips(),
                  const SizedBox(height: V3Spacing.md),
                  if (items.isEmpty)
                    _emptyCard()
                  else
                    for (final a in _visible(items)) ...[
                      _automationCard(a),
                      const SizedBox(height: V3Spacing.sm),
                    ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Apply the design-sheet filter chips.
  List<Automation> _visible(List<Automation> items) {
    switch (_filter) {
      case 'Scheduled':
        // isTimeBased (not triggerType) so SOLAR rules are included — triggerType
        // collapses SOLAR into `manual`, which hid them from this filter.
        return items.where((a) => a.isTimeBased).toList();
      case 'Device':
        return items
            .where((a) => a.triggerType == AutomationTriggerType.nodeState)
            .toList();
      case 'Energy':
        return items.where((a) {
          for (final r in a.rules) {
            final n = (r.config['device_name'] ?? '').toString().toLowerCase();
            if (n.contains('energy') || n.contains('meter')) return true;
          }
          return false;
        }).toList();
      default:
        return items;
    }
  }

  /// The prominent "Create Automation" pill from the design sheet.
  Widget _createPill() {
    return GestureDetector(
      onTap: _busy ? null : () => _openEditor(null),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: V3Colors.primary,
          borderRadius: BorderRadius.circular(V3Radius.lg),
          boxShadow: [
            BoxShadow(
              color: V3Colors.primary.withValues(alpha: 0.45),
              blurRadius: 20,
              spreadRadius: -6,
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 18, color: V3Colors.night),
            SizedBox(width: 8),
            Text('Create Automation',
                style: TextStyle(
                    color: V3Colors.night,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _filterChips() {
    return Row(
      children: [
        for (final f in const ['All', 'Scheduled', 'Device', 'Energy'])
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(() => _filter = f),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _filter == f
                      ? V3Colors.primary
                      : V3Colors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(f,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: _filter == f
                            ? V3Colors.night
                            : V3Colors.primary)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _automationCard(Automation a) {
    return Container(
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: V3Spacing.md, vertical: V3Spacing.sm),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: a.enabled
                        ? V3Colors.primary.withValues(alpha: 0.15)
                        : V3Colors.fill,
                    borderRadius: BorderRadius.circular(V3Radius.md),
                    boxShadow: a.enabled
                        ? [
                            BoxShadow(
                              color:
                                  V3Colors.primary.withValues(alpha: 0.55),
                              blurRadius: 18,
                              spreadRadius: -6,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    _automationIcon(a),
                    size: 20,
                    color: a.enabled ? V3Colors.primary : V3Colors.dim,
                  ),
                ),
                const SizedBox(width: V3Spacing.sm),
                Expanded(
                  child: GestureDetector(
                    // The card is a summary; everything you can DO lives on the
                    // detail page (design sheet panel 2).
                    onTap: _busy ? null : () => _openDetail(a),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: V3Colors.ink,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(_resolvedTriggerLabel(a),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: V3Colors.dim, fontSize: 11.5)),
                        // The action summary line from the design sheet
                        // ("Living Room Light → ON"), so the card says what the
                        // automation DOES, not just when it runs.
                        Text(_actionSummary(a),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: V3Colors.primary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                SHEToggle(
                  value: a.enabled,
                  enabled: !_busy,
                  onChanged: (v) => _run(() => ref
                      .read(automationServiceProvider)
                      .setEnabled(a.id, v)),
                ),
                // Edit / Duplicate / Delete straight on the card. They used to
                // live only behind the detail page, which made them look missing.
                PopupMenuButton<String>(
                  enabled: !_busy,
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: V3Colors.dim),
                  color: V3Colors.surface2,
                  onSelected: (v) {
                    if (v == 'edit') _openEditor(a);
                    if (v == 'duplicate') _duplicate(a);
                    if (v == 'delete') _confirmDelete(a);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
          ),
          // No chip row: the action summary is already in the subtitle, and
          // repeating it made the card tall. No footer either — Run now /
          // Edit / Duplicate / Delete all live on the detail page.

        ],
      ),
    );
  }

  /// Resolve the LIVE user-facing name for a device referenced by a config.
  ///
  /// Renaming a device writes `display_name` (the technical `device_name` never
  /// changes), so reading the stored name is why a renamed device kept showing
  /// its OLD name here. Resolve by the stable id first, then fall back.
  String _deviceLabel(Map<String, dynamic> c) {
    final id = c['node_device_id']?.toString();
    if (id != null && id.isNotEmpty) {
      final devices = ref.read(homeDevicesProvider(_homeId)).valueOrNull;
      if (devices != null) {
        for (final d in devices) {
          if (d.deviceId == id) return d.shownName;
        }
      }
    }
    return c['device_name']?.toString() ??
        c['node_device_id']?.toString() ??
        'Device';
  }

  /// `Automation.triggerLabel`, but with the device's CURRENT (possibly
  /// renamed) name — the model reads the stored `device_name` raw, which is
  /// why a renamed device kept showing its old name on the trigger line.
  String _resolvedTriggerLabel(Automation a) {
    final t = a.trigger;
    if (t['type'] != 'NODE_STATE') return a.triggerLabel;
    final name = _deviceLabel(t);
    return 'When $name.${t['param_name'] ?? ''} '
        '${t['comparator'] ?? '=='} ${t['value']}';
  }

  /// One-line "what it does", e.g. "bedroom light → ON".
  String _actionSummary(Automation a) {
    if (a.rules.isEmpty) return 'No actions';
    final parts = <String>[];
    for (final r in a.rules) {
      if (r.type == 'WRITE_PARAM') {
        final on = (r.config['params'] as Map?)?['Power'] == true;
        parts.add('${_deviceLabel(r.config)} → ${on ? 'ON' : 'OFF'}');
      } else if (r.type == 'ACTIVATE_SCENE') {
        parts.add('Activate scene');
      } else {
        parts.add(r.type);
      }
    }
    return parts.join(' · ');
  }

  /// Chip label for one action, e.g. "bedroom light → ON".
  String _ruleLabel(AutomationRule r) {
    final c = r.config;
    final device = _deviceLabel(c);
    final params = c['params'];
    if (params is Map && params.isNotEmpty) {
      final v = params.values.first;
      final on = v == true || v?.toString().toLowerCase() == 'true';
      return '$device → ${on ? 'ON' : 'OFF'}';
    }
    return '$device → ${r.type}';
  }

  IconData _automationIcon(Automation a) {
    switch (a.trigger['type']?.toString()) {
      case 'SCHEDULE':
        return Icons.schedule;
      // Sunrise/sunset is still a clock trigger — give it a matching glyph
      // instead of falling through to the manual "play" icon.
      case 'SOLAR':
        return Icons.wb_twilight;
      case 'NODE_STATE':
        return Icons.bolt;
      default:
        return Icons.play_circle_outline;
    }
  }

  Widget _emptyCard() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.xl),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: const Column(
        children: [
          Icon(Icons.bolt_outlined, size: 32, color: V3Colors.dim),
          SizedBox(height: V3Spacing.sm),
          Text('No automations yet',
              style:
                  TextStyle(color: V3Colors.ink, fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text('Create one and it runs on its own — no taps needed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: V3Colors.dim, fontSize: 12)),
        ],
      ),
    );
  }
}