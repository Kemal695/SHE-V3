// =============================================================================
// SHE V3 — SHEToggle (custom switch — 60ms snappy + haptic)
// =============================================================================
// V3-DESIGN-SYSTEM §1.10: "60ms transition (faster than Material's 200ms — feels snappy)"
// Haptic on toggle: HapticFeedback.lightImpact()
// Glow synchronized with toggle state.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/she_colors.dart';
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

    final p = context.sheColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // OFF track: a mid-tone neutral, NOT the old textSecondary@30% — over navy
    // (dark) or white (light) that landed at almost the same value as the white
    // thumb, so the two states were hard to tell apart.
    final offTrack = isDark
        ? p.textSecondary.withValues(alpha: 0.42)
        : const Color(0xFFC3CEDC);

    return GestureDetector(
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.45,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, _) {
            final t = _animation.value;
            final on = t > 0.5;
            return Container(
              width: trackWidth,
              height: trackHeight,
              decoration: BoxDecoration(
                // Solid primary when on (was @80%, which read as washed out).
                color: Color.lerp(offTrack, p.primary, t),
                borderRadius: BorderRadius.circular(V3Radius.full),
                border: Border.all(
                  color: on
                      ? p.primary
                      : (isDark
                          ? p.borderStrong
                          : const Color(0xFFAFBDCE)),
                  width: 1,
                ),
                boxShadow: on ? V3Colors.activeGlow(isOn: true) : null,
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: padding +
                        t * (trackWidth - thumbSize - padding * 2),
                    top: padding,
                    child: Container(
                      width: thumbSize,
                      height: thumbSize,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        // A hairline + drop shadow so the white thumb keeps a
                        // visible edge on both the blue (on) and grey (off)
                        // tracks.
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.12),
                          width: 0.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                                alpha: isDark ? 0.38 : 0.20),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
