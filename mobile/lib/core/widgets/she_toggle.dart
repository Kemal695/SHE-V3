// =============================================================================
// SHE V3 — SHEToggle (custom switch — 60ms snappy + haptic)
// =============================================================================
// V3-DESIGN-SYSTEM §1.10: "60ms transition (faster than Material's 200ms — feels snappy)"
// Haptic on toggle: HapticFeedback.lightImpact()
// Glow synchronized with toggle state.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/v3_design_tokens.dart';

class SHEToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  const SHEToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<SHEToggle> createState() => _SHEToggleState();
}

class _SHEToggleState extends State<SHEToggle>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: V3Duration.toggle,   // 60ms — snappy
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    if (widget.value) _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(SHEToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    widget.onChanged(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    const trackWidth = 52.0;
    const trackHeight = 32.0;
    const thumbSize = 28.0;
    const padding = (trackHeight - thumbSize) / 2;

    return GestureDetector(
      onTap: _toggle,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          return Container(
            width: trackWidth,
            height: trackHeight,
            decoration: BoxDecoration(
              color: _animation.value > 0.5
                  ? V3Colors.primary.withValues(alpha: 0.8)
                  : V3Colors.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(V3Radius.full),
              boxShadow: widget.value ? V3Colors.activeGlow(isOn: true) : [],
            ),
            child: Stack(
              children: [
                Positioned(
                  left: padding + _animation.value * (trackWidth - thumbSize - padding * 2),
                  top: padding,
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: const BoxDecoration(
                      color: V3Colors.textPrimary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
