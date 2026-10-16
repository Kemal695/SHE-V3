// =============================================================================
// SHE V3 — Radial quick-action menu (long-press)
// =============================================================================
// V3-DESIGN-SYSTEM §1.10: "Quick actions on long-press: radial menu
// (On / Off / Schedule / Settings)".
//
// Renders actions on an arc around the long-press point over a dimmed backdrop.
// Pure presentation — the caller supplies the actions and their handlers, so this
// stays reusable for devices, scenes and energy cards.
// =============================================================================

import 'package:flutter/material.dart';

import '../../../core/theme/v3_design_tokens.dart';

/// One entry in the radial menu.
class RadialAction {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  const RadialAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });
}

/// Show the radial quick-action menu anchored at [position] (global coords).
Future<T?> showRadialQuickActions<T>({
  required BuildContext context,
  required Offset position,
  required List<RadialAction> actions,
  double radius = 96,
}) {
  return Navigator.of(context).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      pageBuilder: (ctx, _, __) => _RadialMenuOverlay(
        position: position,
        actions: actions,
        radius: radius,
      ),
      transitionsBuilder: (ctx, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}

class _RadialMenuOverlay extends StatefulWidget {
  final Offset position;
  final List<RadialAction> actions;
  final double radius;

  const _RadialMenuOverlay({
    required this.position,
    required this.actions,
    required this.radius,
  });

  @override
  State<_RadialMenuOverlay> createState() => _RadialMenuOverlayState();
}

class _RadialMenuOverlayState extends State<_RadialMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _run(RadialAction a) {
    Navigator.of(context).pop();
    a.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    // Fan the actions over an arc, biased upward so they stay on screen when the
    // press point is near the bottom edge.
    final n = widget.actions.length;
    final sweep = 150 * (3.1415926535897932 / 180); // radians
    final start = 3.1415926535897932 + (3.1415926535897932 - sweep) / 2;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            for (int i = 0; i < n; i++)
              AnimatedBuilder(
                animation: _anim,
                builder: (context, child) {
                  final t = n == 1 ? 0.5 : i / (n - 1);
                  final angle = start + sweep * t;
                  final r = widget.radius * _anim.value;
                  final dx = widget.position.dx + r * _cos(angle);
                  final dy = widget.position.dy + r * _sin(angle);
                  return Positioned(
                    left: dx - 28,
                    top: dy - 28,
                    child: Opacity(
                      opacity: _anim.value.clamp(0.0, 1.0),
                      child: child,
                    ),
                  );
                },
                child: _RadialButton(
                  action: widget.actions[i],
                  onPressed: () => _run(widget.actions[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

double _cos(double a) => _taylorCos(a);
double _sin(double a) => _taylorCos(a - 1.5707963267948966);

// Small local trig helpers so this file needs no dart:math import.
double _taylorCos(double x) {
  var v = x % 6.283185307179586;
  if (v > 3.141592653589793) v -= 6.283185307179586;
  if (v < -3.141592653589793) v += 6.283185307179586;
  final x2 = v * v;
  return 1 -
      x2 / 2 +
      x2 * x2 / 24 -
      x2 * x2 * x2 / 720 +
      x2 * x2 * x2 * x2 / 40320;
}

class _RadialButton extends StatelessWidget {
  final RadialAction action;
  final VoidCallback onPressed;

  const _RadialButton({required this.action, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = action.color ?? V3Colors.primary;
    return SizedBox(
      width: 56,
      height: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'radial_${action.label}',
            mini: true,
            backgroundColor: V3Colors.surface,
            foregroundColor: color,
            elevation: 4,
            onPressed: onPressed,
            child: Icon(action.icon, size: 20),
          ),
          const SizedBox(height: 2),
          Text(
            action.label,
            style:  TextStyle(
              color: V3Colors.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}
