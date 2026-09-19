// =============================================================================
// SHE V3 — Premium Lock Widget (padlock morph: locked → unlocked)
// =============================================================================
// V3-DESIGN-SYSTEM §1.10: "Lock unlock — Padlock morphs locked → unlocked,
// 400ms, Medium impact haptic."
// Used on device cards that are "locked" (GUEST role or schedule-locked).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/v3_design_tokens.dart';

class PremiumLockWidget extends StatefulWidget {
  final bool isLocked;
  final ValueChanged<bool>? onToggle;
  final double size;

  const PremiumLockWidget({
    super.key,
    required this.isLocked,
    this.onToggle,
    this.size = 48,
  });

  @override
  State<PremiumLockWidget> createState() => _PremiumLockWidgetState();
}

class _PremiumLockWidgetState extends State<PremiumLockWidget>
    with TickerProviderStateMixin {
  late AnimationController _morphController;
  late Animation<double> _shackleAnimation;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();
    _morphController = AnimationController(
      duration: V3Duration.slow,   // 400ms — feels substantial
      vsync: this,
    );

    // Shackle rotation: 0 = locked (vertical), 1 = unlocked (rotated 45°)
    _shackleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _morphController, curve: Curves.easeOutBack),
    );

    // Color transition: locked = textSecondary, unlocked = primary
    _colorAnimation = ColorTween(
      begin: V3Colors.textSecondary,
      end: V3Colors.primary,
    ).animate(_morphController);

    if (!widget.isLocked) _morphController.value = 1.0;
  }

  @override
  void didUpdateWidget(PremiumLockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLocked != oldWidget.isLocked) {
      if (widget.isLocked) {
        _morphController.reverse();
      } else {
        _morphController.forward();
      }
      // V3-DESIGN-SYSTEM §1.10: "Medium impact" haptic
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _morphController.dispose();
    super.dispose();
  }

  void _toggle() {
    if (widget.onToggle != null) {
      widget.onToggle!(!widget.isLocked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggle,
      child: AnimatedBuilder(
        animation: _morphController,
        builder: (context, _) {
          return SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _LockPainter(
                progress: _shackleAnimation.value,
                color: _colorAnimation.value ?? V3Colors.textSecondary,
                glowProgress: widget.isLocked ? 0 : _morphController.value,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LockPainter extends CustomPainter {
  final double progress;  // 0 = locked, 1 = unlocked
  final Color color;
  final double glowProgress;

  _LockPainter({
    required this.progress,
    required this.color,
    required this.glowProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    // Glow (when unlocked)
    if (glowProgress > 0) {
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.2 * glowProgress)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12 * glowProgress);
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), size.width / 2.2, glowPaint);
    }

    final center = Offset(size.width / 2, size.height / 2);
    final bodyWidth = size.width * 0.55;
    final bodyHeight = size.height * 0.4;
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy + size.height * 0.1),
        width: bodyWidth,
        height: bodyHeight,
      ),
      Radius.circular(size.width * 0.08),
    );

    // Lock body (rounded rect)
    canvas.drawRRect(bodyRect, paint);

    // Keyhole
    final keyholePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(center.dx, center.dy + size.height * 0.08),
      size.width * 0.05,
      keyholePaint,
    );
    // Keyhole stem
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy + size.height * 0.18),
        width: size.width * 0.03,
        height: size.width * 0.08,
      ),
      keyholePaint,
    );

    // Shackle (arc) — rotates when unlocking
    final shackleRadius = size.width * 0.27;
    final shackleCenter = Offset(center.dx, center.dy + size.height * 0.1 - bodyHeight / 2);

    canvas.save();
    canvas.translate(shackleCenter.dx, shackleCenter.dy);

    // Rotate the shackle: 0° = locked (centered), up to 30° = unlocked (swung right)
    final angle = progress * 0.5; // ~28°
    canvas.rotate(angle);

    // Draw shackle arc (top half)
    final shacklePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: shackleRadius),
      3.14,  // Start from left (π)
      3.14,  // Sweep to right (half circle)
      false,
      shacklePaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LockPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.glowProgress != glowProgress;
}
