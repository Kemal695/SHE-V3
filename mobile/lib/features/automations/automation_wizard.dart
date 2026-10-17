// =============================================================================
// SHE V3 — Automation wizard (When → If (optional) → Then)
// =============================================================================
// The "clean automation" flow from the design sheet: a 3-step full-screen
// wizard instead of one dense dialog, so each step asks exactly one question.
//
//   1. When  — At a specific time / When a device changes / Manual
//   2. If    — optional conditions (only meaningful for a device trigger)
//   3. Then  — pick a device and what to do
//
// Backend is unchanged: it receives the same {trigger, actions} shape the old
// dialog produced. Devices are referenced by their STABLE id (node_device_id)
// as well as by name, so renaming a device never orphans the rule.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/network/api_error.dart';
import '../../core/offline/offline_automations.dart';
import '../../core/theme/v3_design_tokens.dart';
import '../../core/widgets/she_kit.dart';
import '../../core/widgets/she_toggle.dart';
import '../device_detail/node_service.dart' show nodeServiceProvider;
import '../scenes/scene_service.dart'
    show SceneDeviceOption, homeDevicesProvider;
import 'automation_service.dart';
import 'automation_time_wheels.dart' show AutomationTimeWheels;

/// One "Then" entry being authored: a device + what to do to it.
class _ActionEntry {
  SceneDeviceOption? device;
  bool power;

  _ActionEntry({this.device, this.power = true});
}

class AutomationWizardPage extends ConsumerStatefulWidget {
  final String homeId;
  final Automation? existing;

  const AutomationWizardPage({
    super.key,
    required this.homeId,
    this.existing,
  });

  @override
  ConsumerState<AutomationWizardPage> createState() =>
      _AutomationWizardPageState();
}

class _AutomationWizardPageState extends ConsumerState<AutomationWizardPage> {
  int _step = 0; // 0 = When, 1 = If, 2 = Then

  late final TextEditingController _nameCtrl;

  // --- When ---
  AutomationTriggerType _trigger = AutomationTriggerType.schedule;
  int _hour = 6;
  int _minute = 0;
  String _repeat = 'everyDay'; // everyDay | weekdays | weekends

  /// "At sunrise or sunset" is a SCHEDULE at a fixed time under the hood (the
  /// backend has no solar trigger); this only changes the card's wording.
  bool _sunrise = false;

  /// sunrise | sunset — only meaningful while [_sunrise] is true.
  String _solarEvent = 'sunrise';

  // --- Location (foreground geofence) ---
  /// arrive | leave.
  String _locationMode = 'arrive';

  /// Fence radius in metres.
  int _radiusM = 200;

  /// True while the home's point is being captured/uploaded.
  bool _savingLocation = false;

  // --- If (optional) ---
  bool _hasCondition = false;
  SceneDeviceOption? _sourceDevice;
  String _comparator = '==';
  bool _triggerValue = true;

  // --- Then ---
  /// One or more "Then" entries. The backend stores each as its own
  /// `automation_rules` row (it has a `sort_order`), so an automation can drive
  /// several devices — this list is what the "+ Add action" button grows.
  final List<_ActionEntry> _actions = [];

  bool _saving = false;
  List<SceneDeviceOption> _devices = const [];

  /// Device-load state.
  ///
  /// WHY THIS IS TRACKED (bugfix): `_loadDevices` used to swallow every failure
  /// ("Devices unavailable — the wizard still opens"). The wizard did open, but
  /// with an empty list it fell back to `_fallbackDevice` (a placeholder whose
  /// deviceId is ''). `_canAdvance` requires a real deviceId, so BOTH the Next
  /// button on step 0 (for a device trigger) and the Save button on step 2 were
  /// permanently disabled — with nothing on screen explaining why. To the user
  /// that is "I can't edit my automation": the editor opens and cannot be
  /// completed. Surfacing the failure makes it diagnosable and recoverable.
  bool _devicesLoading = true;
  bool _devicesFailed = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    if (e != null) {
      // SOLAR is its own stored trigger type, but the wizard models it as a
      // schedule plus a sunrise/sunset flag. Reading `triggerType` alone mapped
      // SOLAR -> manual (that getter only knows SCHEDULE and NODE_STATE), so
      // EDITING a solar automation silently rewrote it to "run when I tap" and
      // threw the schedule away. Detect it explicitly and restore both halves.
      final isSolar = e.trigger['type'] == 'SOLAR';
      _trigger =
          isSolar ? AutomationTriggerType.schedule : e.triggerType;
      _sunrise = isSolar;
      _solarEvent = (e.trigger['event'] as String?) ?? 'sunrise';
      _hasCondition = e.trigger['type'] == 'NODE_STATE';
      _comparator = (e.trigger['comparator'] as String?) ?? '==';
      _triggerValue = e.trigger['value'] == true;
      final cron = e.trigger['cron'] as String?;
      if (cron != null) {
        final parts = cron.split(RegExp(r'\s+'));
        if (parts.length == 5) {
          _minute = int.tryParse(parts[0]) ?? 0;
          _hour = int.tryParse(parts[1]) ?? 6;
          _repeat = switch (parts[4]) {
            '1-5' => 'weekdays',
            '0,6' => 'weekends',
            _ => 'everyDay',
          };
        }
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevices());
  }

  Future<void> _loadDevices() async {
    setState(() {
      _devicesLoading = true;
      _devicesFailed = false;
    });
    try {
      final devices = await ref.read(homeDevicesProvider(widget.homeId).future);
      if (!mounted) return;
      final e = widget.existing;
      final sourceId = e?.trigger['node_device_id'] as String?;
      final sourceName = e?.trigger['device_name'] as String?;
      final writeRules =
          e?.rules.where((r) => r.type == 'WRITE_PARAM').toList() ??
              const <AutomationRule>[];
      setState(() {
        _devices = devices;
        _devicesLoading = false;
        // An empty list is as blocking as an error — no device can be picked.
        _devicesFailed = devices.isEmpty;
        final firstSwitch = devices.firstWhere(
          (d) => d.isSwitch,
          orElse: () => devices.isNotEmpty ? devices.first : _fallbackDevice,
        );
        _sourceDevice = _match(sourceId, sourceName) ?? firstSwitch;
        // Restore every WRITE_PARAM rule as its own action row.
        _actions.clear();
        if (writeRules.isEmpty) {
          _actions.add(_ActionEntry(device: firstSwitch));
        } else {
          for (final r in writeRules) {
            _actions.add(_ActionEntry(
              device: _match(
                    r.config['node_device_id'] as String?,
                    r.config['device_name'] as String?,
                  ) ??
                  firstSwitch,
              power: (r.config['params'] as Map?)?['Power'] != false,
            ));
          }
        }
      });
    } catch (_) {
      // Recorded rather than swallowed — see _devicesFailed's doc comment.
      if (!mounted) return;
      setState(() {
        _devicesLoading = false;
        _devicesFailed = true;
      });
    }
  }

  /// A do-nothing placeholder so `firstWhere` always has something to return.
  static const SceneDeviceOption _fallbackDevice = SceneDeviceOption(
    nodeId: '',
    nodeName: '',
    deviceName: '',
    deviceType: '',
  );

  /// Resolve a stored reference: stable id first, then the legacy name.
  SceneDeviceOption? _match(String? id, String? name) {
    if (id != null && id.isNotEmpty) {
      for (final d in _devices) {
        if (d.deviceId == id) return d;
      }
    }
    if (name == null || name.isEmpty) return null;
    for (final d in _devices) {
      if (d.deviceName == name) return d;
    }
    return null;
  }

  /// Explains why the wizard cannot be completed, and offers a way out.
  ///
  /// Without this the user just sees a disabled Next/Save button and no reason.
  Widget _devicesBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: V3Spacing.md),
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.warningAlt.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(V3Radius.lg),
        border: Border.all(color: V3Colors.warningAlt.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           Icon(Icons.wifi_off, size: 18, color: V3Colors.warningAlt),
          const SizedBox(width: 10),
           Expanded(
            child: Text(
              'Could not load your devices, so nothing can be picked yet. '
              'Check the connection and try again.',
              style: TextStyle(
                color: V3Colors.ink,
                fontSize: V3Typography.body,
                height: 1.35,
              ),
            ),
          ),
          TextButton(
            onPressed: _devicesLoading ? null : _loadDevices,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String _cron() {
    final dayField = switch (_repeat) {
      'weekdays' => '1-5',
      'weekends' => '0,6',
      _ => '*',
    };
    return '$_minute $_hour * * $dayField';
  }

  String _timeLabel() =>
      '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}';

  /// Sunrise / Sunset picker — the mockup's "At sunrise or sunset" option.
  Widget _solarCard() {
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
          for (final e in const ['sunrise', 'sunset'])
            Expanded(
              child: Padding(
                padding:
                    EdgeInsets.only(right: e == 'sunrise' ? V3Spacing.sm : 0),
                child: GestureDetector(
                  onTap: () => setState(() => _solarEvent = e),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _solarEvent == e
                          ? V3Colors.primary.withValues(alpha: 0.15)
                          : V3Colors.surface2,
                      borderRadius: BorderRadius.circular(V3Radius.lg),
                      border: Border.all(
                          color: _solarEvent == e
                              ? V3Colors.primary
                              : V3Colors.border,
                          width: _solarEvent == e ? 1.5 : 1),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                            e == 'sunrise'
                                ? Icons.wb_twilight
                                : Icons.nights_stay_outlined,
                            size: 16,
                            color: _solarEvent == e
                                ? V3Colors.primary
                                : V3Colors.dim),
                        const SizedBox(width: 6),
                        Text(e == 'sunrise' ? 'Sunrise' : 'Sunset',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: _solarEvent == e
                                    ? V3Colors.primary
                                    : V3Colors.text2)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String get _repeatLabel => switch (_repeat) {
        'weekdays' => 'Weekdays',
        'weekends' => 'Weekends',
        _ => 'Every day',
      };

  bool get _canAdvance {
    switch (_step) {
      case 0:
        // Step 0 only chooses the trigger TYPE. It used to also require a
        // resolved device when the type was "a device changes" — but the device
        // is picked on the NEXT step, so there was nothing the user could do to
        // satisfy it here. Next was therefore dead on arrival for every device
        // triggered automation, which is the "I can't edit my automation"
        // report. The device requirement now lives on the step that owns the
        // picker (case 1).
        return true;
      case 1:
        // Details: a device trigger must name the device it watches. The picker
        // is on this step, so this is satisfiable.
        if (_trigger == AutomationTriggerType.nodeState) {
          return _sourceDevice?.deviceId.isNotEmpty == true;
        }
        return true; // a schedule needs nothing here — conditions are optional
      default:
        // Every action row must have a device.
        return _actions.isNotEmpty &&
            _actions.every((a) => a.device?.deviceId.isNotEmpty == true);
    }
  }

  /// Why the primary button is disabled, or null when it is ready to press.
  ///
  /// Rendered next to the button. A disabled button with no explanation is what
  /// made this screen read as broken — the user saw a bright, tappable-looking
  /// "Next" that silently did nothing.
  String? get _blockedReason {
    if (_saving) return null;
    switch (_step) {
      case 1:
        if (_trigger == AutomationTriggerType.nodeState &&
            !(_sourceDevice?.deviceId.isNotEmpty == true)) {
          if (_devicesFailed) {
            return 'Devices could not be loaded — tap Retry above.';
          }
          if (_devicesLoading) return 'Loading your devices…';
          return 'Choose the device this automation watches.';
        }
        return null;
      case 2:
        if (_actions.isEmpty) return 'Add at least one action.';
        if (_actions.any((a) => !(a.device?.deviceId.isNotEmpty == true))) {
          return 'Every action needs a device — tap it to choose one.';
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please give the automation a name')),
      );
      return;
    }
    final trigger = switch (_trigger) {
      // SOLAR is its own backend trigger: the sunrise/sunset time moves through
      // the year, so a fixed cron would drift out of date.
      AutomationTriggerType.schedule => _sunrise
          ? <String, Object>{'type': 'SOLAR', 'event': _solarEvent}
          : <String, Object>{'type': 'SCHEDULE', 'cron': _cron()},
      AutomationTriggerType.nodeState => <String, Object>{
          'type': 'NODE_STATE',
          'node_id': _sourceDevice?.nodeId ?? '',
          'device_name': _sourceDevice?.deviceName ?? '',
          if ((_sourceDevice?.deviceId ?? '').isNotEmpty)
            'node_device_id': _sourceDevice!.deviceId,
          'param_name': 'Power',
          'comparator': _comparator,
          'value': _triggerValue,
        },
      AutomationTriggerType.manual => <String, Object>{'type': 'MANUAL'},
      AutomationTriggerType.location => <String, Object>{
          'type': 'LOCATION',
          'mode': _locationMode,
          'radius_m': _radiusM,
        },
    };

    // One draft per action row — the backend stores each as its own rule.
    final actions = <AutomationActionDraft>[
      for (final a in _actions)
        if (a.device != null)
          AutomationActionDraft(
            nodeId: a.device!.nodeId,
            deviceName: a.device!.deviceName,
            nodeDeviceId: a.device!.deviceId,
            params: {'Power': a.power},
          ),
    ];

    setState(() => _saving = true);
    try {
      final e = widget.existing;
      if (e != null) {
        // Editing: same offline treatment as creating — cloud first, otherwise
        // apply it to the device and queue the change. Going straight to the
        // cloud made Save die on a 10 s Dio timeout with no connection.
        final res = await ref.read(offlineAutomationServiceProvider).update(
              existing: e,
              homeId: widget.homeId,
              name: name,
              trigger: trigger,
              actions: actions,
            );
        if (!mounted) return;
        if (res.outcome == AutomationSaveOutcome.cloud) {
          Navigator.of(context).pop(true);
          return;
        }
        if (res.outcome == AutomationSaveOutcome.device) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(res.message),
              duration: const Duration(seconds: 6),
            ),
          );
          Navigator.of(context).pop(true);
          return;
        }
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: V3Colors.errorAlt,
            content: Text(res.message),
          ),
        );
        return;
      }

      // Creating. The offline service tries the cloud first; with no link it
      // writes a device-local schedule so the rule still runs (see
      // OfflineAutomationService).
      final res = await ref.read(offlineAutomationServiceProvider).create(
            homeId: widget.homeId,
            name: name,
            trigger: trigger,
            actions: actions,
          );
      if (!mounted) return;

      if (res.outcome == AutomationSaveOutcome.cloud) {
        Navigator.of(context).pop(true);
        return;
      }
      if (res.outcome == AutomationSaveOutcome.device) {
        // Say so explicitly — the rule lives on the device, not the cloud yet.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res.message),
            duration: const Duration(seconds: 6),
          ),
        );
        Navigator.of(context).pop(true);
        return;
      }

      // Offline and not expressible on the device, or the board refused it.
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: V3Colors.errorAlt,
          content: Text(res.message),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: V3Colors.errorAlt,
          // Never dump a raw DioException at the user — that is how "Could not
          // save: DioException [connection timeout]…" reached the screen.
          content: Text('Could not save: ${apiErrorMessage(err)}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['When', 'If (optional)', 'Then'];
    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: Column(
          children: [
            SHEAppBar(
              title: widget.existing == null ? 'Create Automation' : 'Edit',
              onBack: () => Navigator.of(context).pop(),
            ),
            _stepper(),
            const SizedBox(height: V3Spacing.sm),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    V3Spacing.md, 0, V3Spacing.md, V3Spacing.md),
                children: [
                  Text(
                    switch (_step) {
                      0 => 'When does this automation start?',
                      1 => _detailsTitle(),
                      _ => 'What should happen?',
                    },
                    style:  TextStyle(
                        color: V3Colors.ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: V3Spacing.md),
                  if (_devicesLoading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: V3Spacing.md),
                      child: SHESkeleton(height: 52),
                    )
                  else if (_devicesFailed)
                    _devicesBanner(),
                  if (_step == 0) ..._whenStep(),
                  if (_step == 1) ..._detailsStep(),
                  if (_step == 2) ..._thenStep(),
                ],
              ),
            ),
            _footer(titles),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- stepper

  /// Numbered circles with labels beneath, matching the design sheet: the
  /// CURRENT step is a filled blue circle, earlier steps are tinted, later ones
  /// are outlined.
  Widget _stepper() {
    // Step 2 holds the DETAILS of whatever step 1 chose (the time wheels, the
    // sunrise/sunset picker, or the device + condition).
    const labels = ['When', 'Details', 'Then'];

    Widget node(int i) {
      final active = i == _step;
      final done = i < _step;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: active
                  ? V3Colors.primary
                  : done
                      ? V3Colors.primary.withValues(alpha: 0.2)
                      : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? V3Colors.primary
                    : done
                        ? V3Colors.primary.withValues(alpha: 0.4)
                        : V3Colors.border,
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text('${i + 1}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? V3Colors.night
                          : done
                              ? V3Colors.primary
                              : V3Colors.dim)),
            ),
          ),
          const SizedBox(height: 4),
          Text(labels[i],
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? V3Colors.primary : V3Colors.dim)),
        ],
      );
    }

    Widget bar(int i) => Expanded(
          child: Container(
            height: 2,
            margin: const EdgeInsets.only(bottom: 18),
            color: i <= _step
                ? V3Colors.primary
                : V3Colors.primary.withValues(alpha: 0.2),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: V3Spacing.md),
      child: Row(
        children: [
          node(0),
          bar(1),
          node(1),
          bar(2),
          node(2),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- When

  List<Widget> _whenStep() => [
        _option(
          icon: Icons.schedule,
          title: 'At a specific time',
          subtitle: 'Choose a time and repeat',
          selected:
              _trigger == AutomationTriggerType.schedule && !_sunrise,
          onTap: () => setState(() {
            _sunrise = false;
            _trigger = AutomationTriggerType.schedule;
          }),
        ),
        _option(
          icon: Icons.sensors,
          title: 'When a device changes',
          subtitle: 'e.g. lights turn on, motion detected',
          selected: _trigger == AutomationTriggerType.nodeState,
          onTap: () => setState(() {
            _sunrise = false;
            _trigger = AutomationTriggerType.nodeState;
          }),
        ),
        _option(
          icon: Icons.wb_twilight,
          title: 'At sunrise or sunset',
          subtitle: 'Runs at a fixed sunrise/sunset time',
          selected: _sunrise,
          onTap: () => setState(() {
            _sunrise = true;
            _trigger = AutomationTriggerType.schedule;
            _hour = 6;
            _minute = 0;
          }),
        ),
        _option(
          icon: Icons.place_outlined,
          title: 'Location',
          subtitle: 'When you arrive or leave home',
          selected: _trigger == AutomationTriggerType.location,
          onTap: () => setState(() {
            _sunrise = false;
            _trigger = AutomationTriggerType.location;
          }),
        ),
        _option(
          icon: Icons.touch_app,
          title: 'Manual (tap to run)',
          subtitle: 'Only runs when you press Run now',
          selected: _trigger == AutomationTriggerType.manual,
          onTap: () => setState(() {
            _sunrise = false;
            _trigger = AutomationTriggerType.manual;
          }),
        ),
        if (_trigger == AutomationTriggerType.location) ..._locationConfig(),
      ];

  // ------------------------------------------------------------- Location

  /// Arrive/leave + radius, and the one-time "capture the home point" action.
  ///
  /// The fence is evaluated on the phone while the app is open, so the home's
  /// coordinates have to be stored first — without them the watcher cannot run.
  List<Widget> _locationConfig() => [
        const SizedBox(height: V3Spacing.md),
        Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            color: V3Colors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(V3Radius.lg),
            border: Border.all(
              color: V3Colors.primary.withValues(alpha: 0.20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Trigger when I…',
                  style: TextStyle(
                      color: V3Colors.textSecondary, fontSize: 12)),
              const SizedBox(height: V3Spacing.xs),
              Row(
                children: [
                  Expanded(
                    child: _choiceChip(
                      label: 'Arrive home',
                      selected: _locationMode == 'arrive',
                      onTap: () => setState(() => _locationMode = 'arrive'),
                    ),
                  ),
                  const SizedBox(width: V3Spacing.xs),
                  Expanded(
                    child: _choiceChip(
                      label: 'Leave home',
                      selected: _locationMode == 'leave',
                      onTap: () => setState(() => _locationMode = 'leave'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: V3Spacing.md),
              Text('Distance: $_radiusM m',
                  style: TextStyle(
                      color: V3Colors.textSecondary, fontSize: 12)),
              Slider(
                value: _radiusM.toDouble(),
                min: 100,
                max: 1000,
                divisions: 9,
                label: '$_radiusM m',
                onChanged: (v) => setState(() => _radiusM = v.round()),
              ),
              const SizedBox(height: V3Spacing.xs),
              // Capture the home point on first use. Uses the CURRENT position,
              // so it must be pressed while standing at home.
              OutlinedButton.icon(
                onPressed: _savingLocation ? null : _captureHomeLocation,
                icon: _savingLocation
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location, size: 18),
                label: Text(_savingLocation
                    ? 'Saving…'
                    : 'Set home location to my current position'),
              ),
              const SizedBox(height: 4),
              Text(
                'Runs while the app is open. Stand at home when you set this.',
                style: TextStyle(color: V3Colors.dim, fontSize: 11),
              ),
            ],
          ),
        ),
      ];

  Widget _choiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(V3Radius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? V3Colors.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(V3Radius.md),
          border: Border.all(
            color: selected
                ? V3Colors.primary
                : V3Colors.textSecondary.withValues(alpha: 0.30),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? V3Colors.primary : V3Colors.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// Ask for location permission and PATCH the home with the current point.
  Future<void> _captureHomeLocation() async {
    setState(() => _savingLocation = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw 'Location permission is required';
      }
      final pos = await Geolocator.getCurrentPosition();
      await ref.read(nodeServiceProvider).updateHomeLocation(
            widget.homeId,
            latitude: pos.latitude,
            longitude: pos.longitude,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home location saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set home location: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingLocation = false);
    }
  }

  // ---------------------------------------------------------------- Details

  String _detailsTitle() => switch (_trigger) {
        AutomationTriggerType.schedule =>
          _sunrise ? 'Sunrise or sunset' : 'What time?',
        AutomationTriggerType.nodeState => 'Which device?',
        AutomationTriggerType.location => 'Arrive or leave?',
        AutomationTriggerType.manual => 'Nothing to set up',
      };

  /// Step 2 — the DETAILS of whatever step 1 chose. A time trigger shows the
  /// wheels, a solar trigger the sunrise/sunset choice, a device trigger the
  /// device + condition.
  List<Widget> _detailsStep() {
    switch (_trigger) {
      case AutomationTriggerType.schedule:
        if (_sunrise) {
          return [
             Text('Sunrise or sunset?',
                style: TextStyle(color: V3Colors.text2, fontSize: 12.5)),
            const SizedBox(height: V3Spacing.md),
            _solarCard(),
          ];
        }
        return [
           Text('Pick the time it runs',
              style: TextStyle(color: V3Colors.text2, fontSize: 12.5)),
          const SizedBox(height: V3Spacing.md),
          Container(
            padding: const EdgeInsets.symmetric(vertical: V3Spacing.sm),
            decoration: BoxDecoration(
              color: V3Colors.surface,
              borderRadius: BorderRadius.circular(V3Radius.xl),
              border: Border.all(color: V3Colors.border),
            ),
            child: AutomationTimeWheels(
              hour: _hour,
              minute: _minute,
              repeat: _repeat,
              onChanged: (t) => setState(() {
                _hour = t.hour;
                _minute = t.minute;
                _repeat = t.repeat;
              }),
            ),
          ),
        ];
      case AutomationTriggerType.nodeState:
        return [
           Text('Only run if all conditions are met',
              style: TextStyle(color: V3Colors.text2, fontSize: 12.5)),
          const SizedBox(height: V3Spacing.md),
          _devicePicker(
            label: 'Select device',
            value: _sourceDevice,
            onPick: (d) => setState(() => _sourceDevice = d),
          ),
          const SizedBox(height: V3Spacing.sm),
          _conditionRow(),
          const SizedBox(height: V3Spacing.md),
          _addConditionButton(),
        ];
      case AutomationTriggerType.location:
        // The fence is configured on the "When" step, so there is nothing left
        // to pick here — step 2 only confirms the choice.
        return [
           Text('Runs when your phone crosses the home fence.',
              style: TextStyle(color: V3Colors.text2, fontSize: 12.5)),
          const SizedBox(height: V3Spacing.sm),
           Text(
            'Set the distance and capture the home point on the previous step. '
            'This works while the app is open.',
            style: TextStyle(color: V3Colors.dim, fontSize: 11.5),
          ),
        ];
      case AutomationTriggerType.manual:
        return [
          Container(
            padding: const EdgeInsets.all(V3Spacing.md),
            decoration: BoxDecoration(
              color: V3Colors.surface,
              borderRadius: BorderRadius.circular(V3Radius.xl),              border: Border.all(color: V3Colors.border),
            ),
            child:  Text(
              'A manual automation has nothing to configure — it only runs when '
              'you tap Run now. Continue to choose what it does.',
              style: TextStyle(color: V3Colors.text2, fontSize: 12.5),
            ),
          ),
        ];
    }
  }

  /// One condition row: Power | is / is not | ON / OFF.
  Widget _conditionRow() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: V3Spacing.md, vertical: V3Spacing.sm),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
           Icon(Icons.bolt, size: 16, color: V3Colors.primary),
          const SizedBox(width: 8),
           Text('Power',
              style: TextStyle(color: V3Colors.ink, fontSize: 13)),
          const Spacer(),
          DropdownButton<String>(
            value: _comparator,
            dropdownColor: V3Colors.surface2,
            underline: const SizedBox.shrink(),
            style:  TextStyle(color: V3Colors.dim, fontSize: 12.5),
            items: const [
              DropdownMenuItem(value: '==', child: Text('is')),
              DropdownMenuItem(value: '!=', child: Text('is not')),
            ],
            onChanged: (v) => setState(() => _comparator = v ?? '=='),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _triggerValue = !_triggerValue),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              decoration: BoxDecoration(
                color: V3Colors.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(_triggerValue ? 'ON' : 'OFF',
                  style:  TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: V3Colors.night)),
            ),
          ),
        ],
      ),
    );
  }

  /// Dashed "+ Add condition" from the design sheet. Multiple conditions are
  /// not supported by the backend yet, so this says so rather than silently
  /// doing nothing.
  Widget _addConditionButton() {
    return GestureDetector(
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Multiple conditions are not supported yet'),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: V3Spacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(V3Radius.lg),
          border: Border.all(color: V3Colors.border),
        ),
        child:  Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 16, color: V3Colors.text2),
            SizedBox(width: 8),
            Text('Add condition',
                style: TextStyle(color: V3Colors.text2, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- Then

  List<Widget> _thenStep() => [
        for (var i = 0; i < _actions.length; i++) ...[
          _actionCard(i),
          const SizedBox(height: V3Spacing.sm),
        ],
        _addActionButton(),
        const SizedBox(height: V3Spacing.lg),
        TextField(
          controller: _nameCtrl,
          style:  TextStyle(color: V3Colors.ink, fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Automation name',
            labelStyle:  TextStyle(color: V3Colors.dim),
            filled: true,
            fillColor: V3Colors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(V3Radius.lg),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ];

  /// One "Then" card: pick a device, then choose what to do to it. Every card
  /// becomes its own backend rule, so several devices can be driven at once.
  Widget _actionCard(int i) {
    final a = _actions[i];
    return Container(
      padding: const EdgeInsets.all(V3Spacing.md),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(V3Radius.xl),
        border: Border.all(color: V3Colors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('Action ${i + 1}',
                  style:  TextStyle(
                      color: V3Colors.dim,
                      fontSize: 10.5,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_actions.length > 1)
                GestureDetector(
                  onTap: () => setState(() => _actions.removeAt(i)),
                  child:  Icon(Icons.close,
                      size: 16, color: V3Colors.dim),
                ),
            ],
          ),
          const SizedBox(height: V3Spacing.sm),
          _devicePicker(
            label: 'Select device',
            value: a.device,
            onPick: (d) => setState(() => a.device = d),
          ),
          const SizedBox(height: V3Spacing.sm),
          Row(
            children: [
              Expanded(
                child: _actionRow(
                  icon: Icons.power_settings_new,
                  label: 'Turn ON',
                  selected: a.power,
                  onTap: () => setState(() => a.power = true),
                ),
              ),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                child: _actionRow(
                  icon: Icons.power_off,
                  label: 'Turn OFF',
                  selected: !a.power,
                  onTap: () => setState(() => a.power = false),
                ),
              ),
            ],
          ),
          _actionRow(
            icon: Icons.brightness_6_outlined,
            label: 'Set brightness',
            selected: false,
            disabled: true,
            onTap: () {},
          ),
          _actionRow(
            icon: Icons.palette_outlined,
            label: 'Set color',
            selected: false,
            disabled: true,
            onTap: () {},
          ),
        ],
      ),
    );
  }

  /// "+ Add another device" — grows the action list. A solid button (rather than
  /// a faint outline) so it is obviously tappable and easy to hit.
  Widget _addActionButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => setState(() => _actions.add(_ActionEntry(
              device: _devices.isNotEmpty ? _devices.first : null,
            ))),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add another device'),
        style: ElevatedButton.styleFrom(
          backgroundColor: V3Colors.primary.withValues(alpha: 0.15),
          foregroundColor: V3Colors.primary,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(V3Radius.lg)),
        ),
      ),
    );
  }

  /// One row of the Action list (design sheet panel 5): icon · label · check.
  /// Brightness/colour are drawn but marked "Soon" — the backend's WRITE_PARAM
  /// only carries Power today.
  Widget _actionRow({
    required IconData icon,
    required String label,
    required bool selected,
    bool disabled = false,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: GestureDetector(
        onTap: disabled
            ? () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Only turn on / off is supported yet'),
                  ),
                )
            : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: V3Spacing.md, vertical: 14),
          decoration: BoxDecoration(
            color: V3Colors.surface,
            borderRadius: BorderRadius.circular(V3Radius.lg),
            border: Border.all(
                color: selected ? V3Colors.primary : V3Colors.border,
                width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 18,
                  color: disabled
                      ? V3Colors.dim
                      : selected
                          ? V3Colors.primary
                          : V3Colors.text2),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: disabled ? V3Colors.dim : V3Colors.ink,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
              ),
              if (disabled)
                 Text('Soon',
                    style: TextStyle(color: V3Colors.dim, fontSize: 10.5)),
              if (selected)
                 Icon(Icons.check_circle,
                    size: 18, color: V3Colors.primary),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- pieces

  Widget _option({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: V3Spacing.sm),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(V3Spacing.md),
          decoration: BoxDecoration(
            color: V3Colors.surface,
            borderRadius: BorderRadius.circular(V3Radius.xl),
            border: Border.all(
                color: selected ? V3Colors.primary : V3Colors.border,
                width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: selected ? V3Colors.primary : V3Colors.dim),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style:  TextStyle(
                            color: V3Colors.ink,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        style:  TextStyle(
                            color: V3Colors.dim, fontSize: 11.5)),
                  ],
                ),
              ),
              if (selected)
                 Icon(Icons.check_circle,
                    size: 18, color: V3Colors.primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _devicePicker({
    required String label,
    required SceneDeviceOption? value,
    required ValueChanged<SceneDeviceOption> onPick,
  }) {
    return GestureDetector(
      onTap: _devices.isEmpty ? null : () => _pickDevice(label, onPick),
      child: Container(
        padding: const EdgeInsets.all(V3Spacing.md),
        decoration: BoxDecoration(
          color: V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.xl),
          border: Border.all(color: V3Colors.border),
        ),
        child: Row(
          children: [
             Icon(Icons.devices_other, size: 18, color: V3Colors.primary),
            const SizedBox(width: V3Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style:  TextStyle(
                          color: V3Colors.dim, fontSize: 11)),
                  Text(
                    value == null || value.shownName.isEmpty
                        ? 'Select a device'
                        : value.shownName,
                    style:  TextStyle(
                        color: V3Colors.ink,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
             Icon(Icons.chevron_right, size: 18, color: V3Colors.dim),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDevice(
      String title, ValueChanged<SceneDeviceOption> onPick) async {
    final picked = await showModalBottomSheet<SceneDeviceOption>(
      context: context,
      backgroundColor: V3Colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
      ),
      builder: (_) => _DeviceSheet(title: title, devices: _devices),
    );
    if (picked != null) onPick(picked);
  }

  Widget _footer(List<String> titles) {
    final reason = _blockedReason;
    final canGo = _canAdvance && !_saving;

    return Padding(
      padding: const EdgeInsets.all(V3Spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Say WHY the button is disabled, instead of leaving a dead control.
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: V3Spacing.sm),
              child: Row(
                children: [
                   Icon(Icons.info_outline,
                      size: 14, color: V3Colors.warningAlt),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      reason,
                      style:  TextStyle(
                        color: V3Colors.warningAlt,
                        fontSize: V3Typography.meta,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => setState(() => _step -= 1),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: V3Colors.text2,
                      side:  BorderSide(color: V3Colors.border),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(V3Radius.lg)),
                    ),
                    child: const Text('Back'),
                  ),
                ),
              if (_step > 0) const SizedBox(width: V3Spacing.sm),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: canGo
                      ? (_step == 2
                          ? _save
                          : () => setState(() => _step += 1))
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: V3Colors.primary,
                    foregroundColor: V3Colors.night,
                    // 🔴 REQUIRED. ElevatedButton.styleFrom overrides the theme's
                    // disabled colours too, so with only `backgroundColor` set
                    // the button stayed FULLY BRIGHT BLUE when `onPressed` was
                    // null — indistinguishable from an enabled one. The user
                    // tapped a button that looked fine and nothing happened.
                    disabledBackgroundColor:
                        V3Colors.primary.withValues(alpha: 0.18),
                    disabledForegroundColor: V3Colors.dim,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(V3Radius.lg)),
                  ),
                  child: _saving
                      ?  SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: V3Colors.night))
                      : Text(_step == 2 ? 'Save' : 'Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Searchable device picker sheet — mirrors the design's "Select device".
class _DeviceSheet extends StatefulWidget {
  final String title;
  final List<SceneDeviceOption> devices;

  const _DeviceSheet({required this.title, required this.devices});

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  String _query = '';
  String _filter = 'All';

  bool _matchesFilter(SceneDeviceOption d) {
    final n = d.shownName.toLowerCase();
    switch (_filter) {
      case 'Lights':
        return n.contains('light') || n.contains('lamp');
      case 'Appliances':
        return n.contains('socket') || n.contains('plug') ||
            n.contains('outlet');
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.devices
        .where((d) => d.shownName.isNotEmpty)
        .where(_matchesFilter)
        .where((d) =>
            _query.isEmpty ||
            d.shownName.toLowerCase().contains(_query.toLowerCase()))
        .toList();

    return Padding(
      padding: const EdgeInsets.all(V3Spacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.title,
              style:  TextStyle(
                  color: V3Colors.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: V3Spacing.md),
          TextField(
            onChanged: (v) => setState(() => _query = v),
            style:  TextStyle(color: V3Colors.ink, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search devices…',
              hintStyle:  TextStyle(color: V3Colors.dim),
              prefixIcon:  Icon(Icons.search, color: V3Colors.dim),
              filled: true,
              fillColor: V3Colors.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(V3Radius.lg),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: V3Spacing.sm),
          Row(
            children: [
              for (final f in const ['All', 'Lights', 'Appliances'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onTap: () => setState(() => _filter = f),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
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
          ),
          const SizedBox(height: V3Spacing.sm),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (_, i) {
                final d = list[i];
                return ListTile(
                  leading:  Icon(Icons.lightbulb_outline,
                      color: V3Colors.primary),
                  title: Text(d.shownName,
                      style:  TextStyle(
                          color: V3Colors.ink, fontSize: 13.5)),
                  subtitle: Text(d.nodeName,
                      style:  TextStyle(
                          color: V3Colors.dim, fontSize: 11)),
                  onTap: () => Navigator.of(context).pop(d),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
