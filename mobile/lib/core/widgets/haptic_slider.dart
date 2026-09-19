// =============================================================================
// SHE V3 — HapticSlider (circular drag for dimmers/thermostats)
// =============================================================================
// V3-DESIGN-SYSTEM §1.10:
//   - Smooth animation: 300ms ease-out
//   - Haptic on drag: HapticFeedback.selectionClick()
//   - Snap increments: 1% for dimmers, 0.5° for thermostat, 1 for fan speed 1-5
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/v3_design_tokens.dart';

class HapticSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final double snapIncrement;   // 1.0 for dimmers, 0.5 for thermostat, 1.0 for fan
  final ValueChanged<double> onChanged;
  final String? label;
  final String? unit;

  const HapticSlider({
    super.key,
    required this.value,
    this.min = 0,
    this.max = 100,
    this.snapIncrement = 1.0,
    required this.onChanged,
    this.label,
    this.unit,
  });

  @override
  State<HapticSlider> createState() => _HapticSliderState();
}

class _HapticSliderState extends State<HapticSlider>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: V3Duration.medium,   // 300ms ease-out
      vsync: this,
    );
    // NOTE: a CurvedAnimation was previously created here and never read by any
    // widget, so it was removed. The controller itself is still driven in
    // onHorizontalDragEnd, but nothing currently listens to it, so that "snap"
    // pulse has no visible effect — wire it to a builder if you want the
    // settle animation described in V3-DESIGN-SYSTEM §1.10.
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  double _snapToIncrement(double value) {
    final steps = ((value - widget.min) / widget.snapIncrement).round();
    return (widget.min + steps * widget.snapIncrement).clamp(widget.min, widget.max);
  }

  @override
  Widget build(BuildContext context) {
    final displayValue = _dragValue ?? widget.value;
    final percent = ((displayValue - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: V3Spacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.label!,
                  style: const TextStyle(
                    color: V3Colors.textSecondary,
                    fontSize: V3Typography.labelSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '${displayValue.toStringAsFixed(widget.snapIncrement < 1 ? 1 : 0)}${widget.unit ?? ''}',
                  style: const TextStyle(
                    color: V3Colors.primary,
                    fontSize: V3Typography.labelSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        // Custom slider track
        GestureDetector(
          onHorizontalDragUpdate: (details) {
            final box = context.findRenderObject() as RenderBox;
            final width = box.size.width - 40;  // padding
            final newPos = ((details.localPosition.dx - 20) / width).clamp(0.0, 1.0);
            final newValue = widget.min + newPos * (widget.max - widget.min);
            final snapped = _snapToIncrement(newValue);

            if (snapped != _dragValue) {
              // Haptic on snap (V3-DESIGN-SYSTEM §1.10)
              HapticFeedback.selectionClick();
              setState(() => _dragValue = snapped);
            }
          },
          onHorizontalDragEnd: (_) {
            if (_dragValue != null) {
              widget.onChanged(_dragValue!);
              _animController.forward(from: 0).then((_) => _animController.reset());
            }
            setState(() => _dragValue = null);
          },
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                // Track background
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: V3Colors.textSecondary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(V3Radius.full),
                  ),
                ),
                // Filled portion
                FractionallySizedBox(
                  widthFactor: percent,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: V3Colors.primary,
                      borderRadius: BorderRadius.circular(V3Radius.full),
                      boxShadow: V3Colors.activeGlow(isOn: true),
                    ),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 20 + percent * (MediaQuery.of(context).size.width - 80 - 40) - 12,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: V3Colors.textPrimary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: V3Colors.primary.withValues(alpha: 0.4),
                          blurRadius: 8,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
