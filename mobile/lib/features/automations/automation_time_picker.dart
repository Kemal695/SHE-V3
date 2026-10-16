// =============================================================================
// SHE V3 — Automation time picker (design sheet panel 6)
// =============================================================================
// Two snap wheels (hour : minute) + an AM/PM segment + a Repeat row, styled with
// the V3 tokens instead of a stock Material time dialog.
//
//   showAutomationTimePicker(context, hour: 6, minute: 0, repeat: 'everyDay')
//     -> (hour: int, minute: int, repeat: String)?
//
// `hour` in and out is 24-hour; the wheels display 12-hour + AM/PM, which is
// what the design sheet draws.
// =============================================================================

import 'package:flutter/material.dart';

import '../../core/theme/v3_design_tokens.dart';

typedef AutomationTime = ({int hour, int minute, String repeat});

Future<AutomationTime?> showAutomationTimePicker(
  BuildContext context, {
  required int hour,
  required int minute,
  required String repeat,
}) {
  return showModalBottomSheet<AutomationTime>(
    context: context,
    backgroundColor: V3Colors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(V3Radius.xl)),
    ),
    builder: (_) => _TimeWheelSheet(
      hour: hour,
      minute: minute,
      repeat: repeat,
    ),
  );
}

class _TimeWheelSheet extends StatefulWidget {
  final int hour;
  final int minute;
  final String repeat;

  const _TimeWheelSheet({
    required this.hour,
    required this.minute,
    required this.repeat,
  });

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  static const double _itemExtent = 42;

  late int _hour12; // 1..12
  late bool _pm;
  late int _minute; // 0..59
  late String _repeat;

  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  @override
  void initState() {
    super.initState();
    final h24 = widget.hour;
    _pm = h24 >= 12;
    _hour12 = h24 % 12 == 0 ? 12 : h24 % 12;
    _minute = widget.minute;
    _repeat = widget.repeat;
    _hourCtrl = FixedExtentScrollController(initialItem: _hour12 - 1);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          V3Spacing.md, V3Spacing.md, V3Spacing.md, V3Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
           Text('Select time',
              style: TextStyle(
                  color: V3Colors.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: V3Spacing.md),

          // ── hour : minute wheels ─────────────────────────────────────────
          SizedBox(
            height: _itemExtent * 3,
            child: Stack(
              children: [
                // Selection band behind the wheels.
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
                    Expanded(child: _wheel(
                      controller: _hourCtrl,
                      count: 12,
                      label: (i) => (i + 1).toString().padLeft(2, '0'),
                      onChanged: (i) => setState(() => _hour12 = i + 1),
                    )),
                     Text(':',
                        style: TextStyle(
                            color: V3Colors.ink,
                            fontSize: 22,
                            fontWeight: FontWeight.w700)),
                    Expanded(child: _wheel(
                      controller: _minuteCtrl,
                      count: 60,
                      label: (i) => i.toString().padLeft(2, '0'),
                      onChanged: (i) => setState(() => _minute = i),
                    )),
                    const SizedBox(width: V3Spacing.sm),
                    // ── AM / PM ─────────────────────────────────────────────
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

          // ── Repeat ──────────────────────────────────────────────────────
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
                   Icon(Icons.repeat, size: 18, color: V3Colors.primary),
                  const SizedBox(width: V3Spacing.sm),
                   Text('Repeat',
                      style: TextStyle(color: V3Colors.dim, fontSize: 12.5)),
                  const Spacer(),
                  Text(_repeatLabel,
                      style:  TextStyle(
                          color: V3Colors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                   Icon(Icons.chevron_right,
                      size: 18, color: V3Colors.dim),
                ],
              ),
            ),
          ),

          const SizedBox(height: V3Spacing.md),

          // ── Cancel / Save ───────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: V3Colors.text2,
                    side:  BorderSide(color: V3Colors.border),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(V3Radius.lg)),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: V3Spacing.sm),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop((
                    hour: _hour24,
                    minute: _minute,
                    repeat: _repeat,
                  )),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: V3Colors.primary,
                    foregroundColor: V3Colors.night,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(V3Radius.lg)),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
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
             Text('Repeat',
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
                  style:  TextStyle(color: V3Colors.ink, fontSize: 13.5),
                ),
                trailing: _repeat == r
                    ?  Icon(Icons.check, color: V3Colors.primary, size: 18)
                    : null,
                onTap: () => Navigator.of(context).pop(r),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _repeat = picked);
  }

  Widget _ampm(String label, bool selected) {
    return GestureDetector(
      onTap: () => setState(() => _pm = label == 'PM'),
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
          final selected = controller.hasClients
              ? controller.selectedItem == i
              : false;
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
