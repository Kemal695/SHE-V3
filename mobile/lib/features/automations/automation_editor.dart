// =============================================================================
// SHE V3 — Automation editor dialog
// =============================================================================
// Trigger: MANUAL | SCHEDULE (cron) | NODE_STATE (device.param comparator value)
// Action:  WRITE_PARAM — pick a device and choose on/off.
// ACTIVATE_SCENE / NOTIFICATION are accepted by the backend but have no editor yet.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import 'automation_service.dart';
import '../scenes/scene_service.dart'
    show homeDevicesProvider, SceneDeviceOption;

/// Result handed back to the screen.
class AutomationEditorResult {
  final String name;
  final Map<String, Object> trigger;
  final List<AutomationActionDraft> actions;

  const AutomationEditorResult({
    required this.name,
    required this.trigger,
    required this.actions,
  });
}

class AutomationEditorDialog extends ConsumerStatefulWidget {
  final String homeId;
  final Automation? existing;

  const AutomationEditorDialog({
    super.key,
    required this.homeId,
    this.existing,
  });

  @override
  ConsumerState<AutomationEditorDialog> createState() =>
      _AutomationEditorDialogState();
}

class _AutomationEditorDialogState
    extends ConsumerState<AutomationEditorDialog> {
  static const List<String> _comparators = ['==', '!=', '>', '>=', '<', '<='];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _cronCtrl;

  AutomationTriggerType _trigger = AutomationTriggerType.manual;
  String _paramName = 'Power';
  String _comparator = '==';
  bool _triggerValue = true;

  SceneDeviceOption? _sourceDevice;
  SceneDeviceOption? _actionDevice;
  bool _actionPower = true;
  bool _saving = false;

  /// True when the current Schedule trigger's cron text looks parseable.
  /// Lets the editor show inline validation instead of waiting for the backend
  /// to reject it (which still happens — this is a UX guard, not a security one).
  bool _cronIsValid = true;

  /// Schedule picker state. A raw cron string is accurate but meaningless to most
  /// people — "0 6 * * *" does not obviously say "every day at 06:00". The picker
  /// drives these, and [_cronFromPicker] derives the cron, so the user never has
  /// to read cron unless they deliberately choose Custom.
  int _schedHour = 6;
  int _schedMinute = 0;

  /// everyDay | weekdays | weekends | custom
  String _repeat = 'everyDay';

  /// A cron field may be: "*", a number (0-59), a range "a-b", a step "a-b/k",
  /// a list "a,b,c", or "*/k". Names for month/weekday are not allowed here
  /// (kept the editor to digits-only for clarity). 5 fields separated by spaces.
  static final RegExp _cronFieldPattern = RegExp(r'^[\d\*\/\,\-]+$');

  bool _looksLikeValidCron(String expr) {
    final t = expr.trim();
    if (t.isEmpty) return false;
    if (t.split(RegExp(r'\s+')).length != 5) return false;
    return t
        .split(RegExp(r'\s+'))
        .every((f) => f.isNotEmpty && _cronFieldPattern.hasMatch(f));
  }

  /// Builds a 5-field cron from the friendly picker.
  String _cronFromPicker() {
    final dayField = switch (_repeat) {
      'weekdays' => '1-5',      // Mon–Fri
      'weekends' => '0,6',      // Sun + Sat
      _ => '*',                 // everyDay (and custom falls back to *)
    };
    return '$_schedMinute $_schedHour * * $dayField';
  }

  /// "06:00" — 24-hour, matching the cron the backend expects.
  String get _timeLabel =>
      '${_schedHour.toString().padLeft(2, '0')}:${_schedMinute.toString().padLeft(2, '0')}';

  String get _repeatLabel => switch (_repeat) {
        'weekdays' => 'on weekdays',
        'weekends' => 'on weekends',
        'custom' => '',
        _ => 'every day',
      };

  /// The whole rule in one plain sentence, so the user can confirm what they built
  /// before saving rather than decoding a cron expression afterwards.
  String _summary() {
    final when = _trigger == AutomationTriggerType.schedule
        ? 'At $_timeLabel ${_repeatLabel}'.trim()
        : _trigger == AutomationTriggerType.manual
            ? 'When you tap Run'
            : 'When ${_sourceDevice?.shownName ?? 'a device'} changes';

    final action = _actionDevice == null
        ? 'do nothing'
        : 'turn ${_actionDevice!.shownName} ${_actionPower ? 'on' : 'off'}';

    return '$when → $action';
  }

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _cronCtrl = TextEditingController(text: e?.cron ?? '0 6 * * *');
    _cronIsValid = _looksLikeValidCron(_cronCtrl.text);
    // Re-validate on every keystroke so the Save button / helper text react live.
    _cronCtrl.addListener(() {
      final v = _looksLikeValidCron(_cronCtrl.text);
      if (v != _cronIsValid) setState(() => _cronIsValid = v);
    });
    if (e != null) {
      _trigger = e.triggerType;
      _paramName = (e.trigger['param_name'] as String?) ?? 'Power';
      _comparator = (e.trigger['comparator'] as String?) ?? '==';
      _triggerValue = e.trigger['value'] == true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
  }

  Future<void> _loadDevices() async {
    try {
      final devices =
          await ref.read(homeDevicesProvider(widget.homeId).future);
      if (!mounted || devices.isEmpty) return;
      final e = widget.existing;
      final sourceId = e?.trigger['node_device_id'] as String?;
      final sourceName = e?.trigger['device_name'] as String?;
      final actionCfg =
          e?.rules.where((r) => r.type == 'WRITE_PARAM').firstOrNull;
      final actionId = actionCfg?.config['node_device_id'] as String?;
      final actionName = actionCfg?.config['device_name'] as String?;
      setState(() {
        // Prefer a controllable switch for the default action — Diagnostics/OTA
        // make no sense to "switch" and confusingly the backend often lists them
        // first. Same idea applies to the trigger source.
        final firstSwitch = devices.firstWhere(
          (d) => d.isSwitch,
          orElse: () => devices.first,
        );
        _sourceDevice = _match(devices, sourceId, sourceName) ?? firstSwitch;
        _actionDevice = _match(devices, actionId, actionName) ?? firstSwitch;
        final cfg =
            e?.rules.where((r) => r.type == 'WRITE_PARAM').firstOrNull;
        final params = (cfg?.config['params'] as Map? ?? const {});
        _actionPower = params['Power'] == true;
      });
    } catch (_) {
      // Devices unavailable — editor still opens with empty pickers.
    }
  }

  /// Resolve a stored device reference to a live device.
  ///
  /// Prefers the stable `node_device_id`, so a device that has since been
  /// RENAMED still resolves (and the editor shows its current name). Falls back
  /// to the legacy stored name for automations saved before ids were recorded.
  SceneDeviceOption? _match(
      List<SceneDeviceOption> devices, String? id, String? name) {
    if (id != null && id.isNotEmpty) {
      for (final d in devices) {
        if (d.deviceId == id) return d;
      }
    }
    if (name == null) return null;
    for (final d in devices) {
      if (d.deviceName == name) return d;
    }
    return null;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cronCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please give the automation a name')),
      );
      return;
    }
    // Client-side guard so a malformed cron (e.g. "0 609", the shape that left a
    // rule permanently dead) never reaches the backend. The backend validates too
    // — this just gives instant feedback instead of a failed round-trip.
    if (_trigger == AutomationTriggerType.schedule && !_cronIsValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cron needs 5 fields — minute hour day-of-month month day-of-week, '
            'e.g. "0 6 * * *" for daily at 06:00',
          ),
        ),
      );
      return;
    }

    final Map<String, Object> trigger = switch (_trigger) {
      AutomationTriggerType.schedule => {
          'type': 'SCHEDULE',
          // Custom keeps whatever was typed; otherwise the picker is the source
          // of truth so the two can never disagree.
          'cron': _repeat == 'custom'
              ? _cronCtrl.text.trim()
              : _cronFromPicker(),
        },
      AutomationTriggerType.nodeState => {
          'type': 'NODE_STATE',
          'node_id': _sourceDevice?.nodeId ?? '',
          'device_name': _sourceDevice?.deviceName ?? '',
          // Stable id — the backend prefers it, so a later rename cannot orphan
          // this trigger (the bug where an automation kept the OLD device name).
          if ((_sourceDevice?.deviceId ?? '').isNotEmpty)
            'node_device_id': _sourceDevice!.deviceId,
          'param_name': _paramName,
          'comparator': _comparator,
          'value': _triggerValue,
        },
      AutomationTriggerType.manual => {'type': 'MANUAL'},
    };

    final actions = <AutomationActionDraft>[];
    if (_actionDevice != null) {
      actions.add(
        AutomationActionDraft(
          nodeId: _actionDevice!.nodeId,
          deviceName: _actionDevice!.deviceName,
          nodeDeviceId: _actionDevice!.deviceId,
          params: {'Power': _actionPower},
        ),
      );
    }

    setState(() => _saving = true);
    try {
      if (!mounted) return;
      Navigator.pop(
        context,
        AutomationEditorResult(
          name: name,
          trigger: trigger,
          actions: actions,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(homeDevicesProvider(widget.homeId));

    return AlertDialog(
      backgroundColor: V3Colors.surface,
      title: Text(
        widget.existing == null ? 'New automation' : 'Edit automation',
        style: const TextStyle(color: V3Colors.textPrimary),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                style: const TextStyle(color: V3Colors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  labelStyle: TextStyle(color: V3Colors.textSecondary),
                ),
              ),
              const SizedBox(height: V3Spacing.md),
              const Text(
                'When',
                style: TextStyle(color: V3Colors.textSecondary, fontSize: 12),
              ),
              DropdownButton<AutomationTriggerType>(
                value: _trigger,
                dropdownColor: V3Colors.surface,
                style: const TextStyle(color: V3Colors.textPrimary),
                items: AutomationTriggerType.values
                    .map(
                      (t) => DropdownMenuItem<AutomationTriggerType>(
                        value: t,
                        child: Text(t.label),
                      ),
                    )
                    .toList(),
                onChanged: (v) =>
                    setState(() => _trigger = v ?? AutomationTriggerType.manual),
              ),
              if (_trigger == AutomationTriggerType.schedule)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.schedule,
                                size: 16, color: V3Colors.primary),
                            label: Text('At $_timeLabel',
                                style: const TextStyle(
                                    color: V3Colors.textPrimary)),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay(
                                    hour: _schedHour, minute: _schedMinute),
                              );
                              if (picked != null && mounted) {
                                setState(() {
                                  _schedHour = picked.hour;
                                  _schedMinute = picked.minute;
                                  _cronCtrl.text = _cronFromPicker();
                                  _cronIsValid = true;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: V3Spacing.sm),
                        DropdownButton<String>(
                          value: _repeat,
                          dropdownColor: V3Colors.surface,
                          style: const TextStyle(color: V3Colors.textPrimary),
                          items: const [
                            DropdownMenuItem(
                                value: 'everyDay', child: Text('Every day')),
                            DropdownMenuItem(
                                value: 'weekdays', child: Text('Weekdays')),
                            DropdownMenuItem(
                                value: 'weekends', child: Text('Weekends')),
                            DropdownMenuItem(
                                value: 'custom', child: Text('Custom cron')),
                          ],
                          onChanged: (v) => setState(() {
                            _repeat = v ?? 'everyDay';
                            _cronCtrl.text = _cronFromPicker();
                            _cronIsValid = true;
                          }),
                        ),
                      ],
                    ),
                    // Raw cron is only surfaced for people who ask for it — it is
                    // accurate but unreadable, which was the original confusion.
                    if (_repeat == 'custom') ...[
                      const SizedBox(height: V3Spacing.sm),
                      TextField(
                        controller: _cronCtrl,
                        style: const TextStyle(color: V3Colors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'Cron (min hour day month weekday)',
                          hintText: '0 6 * * *',
                          labelStyle:
                              const TextStyle(color: V3Colors.textSecondary),
                          hintStyle:
                              const TextStyle(color: V3Colors.textSecondary),
                          errorText: _cronIsValid
                              ? null
                              : 'Needs 5 fields, e.g. "0 6 * * *"',
                          errorStyle: const TextStyle(
                              color: V3Colors.error, fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
              if (_trigger == AutomationTriggerType.nodeState)
                devicesAsync.when(
                  loading: () =>
                      const CircularProgressIndicator(color: V3Colors.primary),
                  error: (e, _) => Text(
                    'Devices unavailable: $e',
                    style: const TextStyle(color: V3Colors.error),
                  ),
                  data: (devices) {
                    if (devices.isEmpty) {
                      return const Text(
                        'No devices found in this home.',
                        style: TextStyle(color: V3Colors.textSecondary),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButton<SceneDeviceOption>(
                          value: _sourceDevice,
                          dropdownColor: V3Colors.surface,
                          style: const TextStyle(color: V3Colors.textPrimary),
                          items: devices
                              .map(
                                (d) => DropdownMenuItem<SceneDeviceOption>(
                                  value: d,
                                  child: Text(d.label),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => _sourceDevice = v),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: TextEditingController(
                                    text: _paramName),
                                style: const TextStyle(
                                    color: V3Colors.textPrimary),
                                decoration: const InputDecoration(
                                  labelText: 'Param',
                                  labelStyle: TextStyle(
                                      color: V3Colors.textSecondary),
                                ),
                                onChanged: (v) => _paramName = v,
                              ),
                            ),
                            const SizedBox(width: V3Spacing.sm),
                            DropdownButton<String>(
                              value: _comparator,
                              dropdownColor: V3Colors.surface,
                              style:
                                  const TextStyle(color: V3Colors.textPrimary),
                              items: _comparators
                                  .map(
                                    (c) => DropdownMenuItem<String>(
                                      value: c,
                                      child: Text(c),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _comparator = v ?? '=='),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('matches',
                                style: TextStyle(
                                    color: V3Colors.textSecondary)),
                            const SizedBox(width: V3Spacing.sm),
                            Switch(
                              value: _triggerValue,
                              activeColor: V3Colors.primary,
                              onChanged: (v) =>
                                  setState(() => _triggerValue = v),
                            ),
                            Text(_triggerValue ? 'On' : 'Off',
                                style: const TextStyle(
                                    color: V3Colors.textPrimary)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              const Divider(color: Colors.white24),
              const SizedBox(height: V3Spacing.sm),
              const Text(
                'Then switch',
                style: TextStyle(color: V3Colors.textSecondary, fontSize: 12),
              ),
              devicesAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
                data: (devices) {
                  if (devices.isEmpty) return const SizedBox.shrink();
                  // Two lines, not one — a single Row with DropdownButton (intrinsic
                  // width from the longest label, e.g. "Diagnostics · SHE-8-AE5328") +
                  // Switch + label overflowed by ~49 px. Putting the dropdown on its
                  // own line and the toggle below guarantees it fits any device.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButton<SceneDeviceOption>(
                        value: _actionDevice,
                        dropdownColor: V3Colors.surface,
                        isExpanded: true,
                        style: const TextStyle(color: V3Colors.textPrimary),
                        items: devices
                            .map(
                              (d) => DropdownMenuItem<SceneDeviceOption>(
                                value: d,
                                child: Text(d.label),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _actionDevice = v),
                      ),
                      Row(
                        children: [
                          Switch(
                            value: _actionPower,
                            activeColor: V3Colors.primary,
                            onChanged: (v) => setState(() => _actionPower = v),
                          ),
                          Text(_actionPower ? 'On' : 'Off',
                              style: const TextStyle(
                                  color: V3Colors.textPrimary)),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const Divider(color: Colors.white24),
              const SizedBox(height: V3Spacing.sm),
              // Plain-language preview. The whole point is that the user can
              // confirm the rule reads correctly BEFORE saving, instead of
              // decoding a cron expression after the fact.
              Text(
                _summary(),
                style: const TextStyle(
                  color: V3Colors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: V3Colors.textSecondary),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: V3Colors.primary,
            // See app.dart: a local backgroundColor also overrides the disabled
            // colours, so a disabled button would still look live.
            disabledBackgroundColor: V3Colors.primary.withValues(alpha: 0.18),
            disabledForegroundColor:
                V3Colors.textSecondary.withValues(alpha: 0.5),
          ),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}