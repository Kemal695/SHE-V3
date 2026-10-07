// =============================================================================
// SHE V3 — Inline time wheels (design sheet panel 6)
// =============================================================================
// Two snap wheels (hour : minute) + an AM/PM segment + a Repeat row, meant to be
// EMBEDDED directly in the wizard's step 2 — not shown in a sheet.
//
//   AutomationTimeWheels(
//     hour: 6, minute: 0, repeat: 'everyDay',
//     onChanged: (t) => ...,
//   )
//
// `hour` in and out is 24-hour; the wheels display 12-hour + AM/PM.
// =============================================================================

import 'package:flutter/material.dart';

import '../../core/theme/v3_design_tokens.dart';

typedef AutomationTime = ({int hour, int minute, String repeat});

class AutomationTimeWheels extends StatefulWidget {
  final int hour;
  final int minute;
  final String repeat;
  final ValueChanged<AutomationTime> onChanged;

  const AutomationTimeWheels({
    super.key,
    required this.hour,
    required this.minute,
    required this.repeat,
    required this.onChanged,
  });

  @override
  State<AutomationTimeWheels> createState() => _AutomationTimeWheelsState();
}

class _AutomationTimeWheelsState extends State<AutomationTimeWheels> {
  static const double _itemExtent = 42;

  late int _hour12; // 1..12
  late bool _pm;
  late int _minute;
  late String _repeat;

  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  @override
  void initState() {
    super.initState();
    _syncFromWidget();
    _hourCtrl = FixedExtentScrollController(initialItem: _hour12 - 1);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  void _syncFromWidget() {
    final h24 = widget.hour;
    _pm = h24 >= 12;
    _hour12 = h24 % 12 == 0 ? 12 : h24 % 12;
    _minute = widget.minute;
    _repeat = widget.repeat;
  }

  /// The last value we pushed up. `onChanged` makes the parent rebuild and hand
  /// the same value straight back; without this guard we would `jumpToItem` on
  /// that echo, snapping the wheel back under the user's finger — which made the
  /// picker impossible to rotate at all.
  AutomationTime? _lastEmitted;

  @override
  void didUpdateWidget(covariant AutomationTimeWheels old) {
    super.didUpdateWidget(old);
    final echo = _lastEmitted != null &&
        _lastEmitted!.hour == widget.hour &&
        _lastEmitted!.minute == widget.minute;
    if (echo) return; // our own change coming back — leave the wheels alone
    // Genuine external change (e.g. "sunrise" set the hour): follow it.
    if (old.hour != widget.hour || old.minute != widget.minute) {
      _syncFromWidget();
      if (_hourCtrl.hasClients) _hourCtrl.jumpToItem(_hour12 - 1);
      if (_minuteCtrl.hasClients) _minuteCtrl.jumpToItem(_minute);
    }
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  int get _hour24 {
    var h = _hour12 % 12; // 12 -> 0
    if (_pm) h += 12;
    return h;
  }

  void _emit() {
    _lastEmitted = (hour: _hour24, minute: _minute, repeat: _repeat);
    widget.onChanged(_lastEmitted!);
  }

  String get _repeatLabel => switch (_repeat) {
        'weekdays' => 'Weekdays',
        'weekends' => 'Weekends',
        _ => 'Every day',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: _itemExtent * 3,
          child: Stack(
            children: [
              Center(
                child: Container(
                  height: _itemExtent,
                  decoration: BoxDecoration(
                    color: V3Colors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(V3Radius.md),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _wheel(
                      controller: _hourCtrl,
                      count: 12,
                      label: (i) => (i + 1).toString().padLeft(2, '0'),
                      onChanged: (i) {
                        setState(() => _hour12 = i + 1);
                        _emit();
                      },
                    ),
                  ),
                  const Text(':',
                      style: TextStyle(
                          color: V3Colors.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w700)),
                  Expanded(
                    child: _wheel(
                      controller: _minuteCtrl,
                      count: 60,
                      label: (i) => i.toString().padLeft(2, '0'),
                      onChanged: (i) {
                        setState(() => _minute = i);
                        _emit();
                      },
                    ),
                  ),
                  const SizedBox(width: V3Spacing.sm),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ampm('AM', !_pm),
                      const SizedBox(height: 6),
                      _ampm('PM', _pm),
                    ],
                  ),
                  const SizedBox(width: V3Spacing.sm),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: V3Spacing.md),
        GestureDetector(
          onTap: _pickRepeat,
          child: Container(
            padding: const EdgeInsets.all(V3Spacing.md),
            decoration: BoxDecoration(
              color: V3Colors.surface2,
              borderRadius: BorderRadius.circular(V3Radius.lg),
            ),
            child: Row(
              children: [
                const Icon(Icons.repeat, size: 18, color: V3Colors.primary),
                const SizedBox(width: V3Spacing.sm),
                const Text('Repeat',
                    style: TextStyle(color: V3Colors.dim, fontSize: 12.5)),
                const Spacer(),
                Text(_repeatLabel,
                    style: const TextStyle(
                        color: V3Colors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const Icon(Icons.chevron_right, size: 18, color: V3Colors.dim),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickRepeat() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: V3Colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(V3Spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Repeat',
                style: TextStyle(
                    color: V3Colors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: V3Spacing.sm),
            for (final r in const ['everyDay', 'weekdays', 'weekends'])
              ListTile(
                title: Text(
                  switch (r) {
                    'weekdays' => 'Weekdays (Mon–Fri)',
                    'weekends' => 'Weekends (Sat–Sun)',
                    _ => 'Every day',
                  },
                  style: const TextStyle(color: V3Colors.ink, fontSize: 13.5),
                ),
                trailing: _repeat == r
                    ? const Icon(Icons.check, color: V3Colors.primary, size: 18)
                    : null,
                onTap: () => Navigator.of(context).pop(r),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      setState(() => _repeat = picked);
      _emit();
    }
  }

  Widget _ampm(String label, bool selected) {
    return GestureDetector(
      onTap: () {
        setState(() => _pm = label == 'PM');
        _emit();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? V3Colors.primary : V3Colors.fill,
          borderRadius: BorderRadius.circular(V3Radius.md),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? V3Colors.night : V3Colors.text2)),
      ),
    );
  }

  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required String Function(int) label,
    required ValueChanged<int> onChanged,
  }) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: _itemExtent,
      perspective: 0.003,
      diameterRatio: 1.8,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: count,
        builder: (_, i) {
          // Enlarge + brighten the centred item so it is obvious the wheel is
          // moving (the old flat style made a rotating wheel look static).
          final selected =
              controller.hasClients && controller.selectedItem == i;
          return Center(
            child: Text(
              label(i),
              style: TextStyle(
                fontSize: selected ? 22 : 17,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? V3Colors.ink : V3Colors.dim,
              ),
            ),
          );
        },
      ),
    );
  }
}
