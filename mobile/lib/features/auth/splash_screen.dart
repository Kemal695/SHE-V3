// =============================================================================
// SHE V3 — Splash Screen (V3-UI-REDESIGN)
// =============================================================================
// Ported from the prototype's `Splash` panel (screens/auth.tsx).
//
// Visual: full-bleed skyline photo, navy scrim gradient, a glowing rounded logo
// tile, the "Smart Home Ethiopia" wordmark with the SHE initialism, and a
// loading bar that fills over ~1.7 s before auto-advancing to Onboarding.
//
// Behaviour is deliberately self-contained: this screen owns only its animation
// and a single timer. It performs NO auth check and NO network call — the router
// redirect decides where an authenticated user lands, so this can never bounce
// a logged-in user back to onboarding.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _barController;
  Timer? _advance;

  @override
  void initState() {
    super.initState();

    // Logo: fade + scale-in, mirroring framer-motion's [0.22, 1, 0.36, 1] ease.
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    )..forward();

    // Loading bar: fills over 1.7 s.
    _barController = AnimationController(
      duration: const Duration(milliseconds: 1700),
      vsync: this,
    )..forward();

    // Auto-advance after 2.1 s, exactly like the prototype's setTimeout.
    _advance = Timer(const Duration(milliseconds: 2100), _goNext);
  }

  void _goNext() {
    if (!mounted) return;
    // Replace, so back from onboarding cannot return to the splash.
    context.go('/onboarding');
  }

  @override
  void dispose() {
    _advance?.cancel();
    _logoController.dispose();
    _barController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: V3Colors.background,
      body: GestureDetector(
        // Tapping skips the wait, same as the prototype.
        onTap: _goNext,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ---- Skyline photo ----
            Image.asset(
              'assets/img/skyline.png',
              fit: BoxFit.cover,
              // A missing asset must never crash the launch path.
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),

            // ---- Navy scrim: from-she-bg/70 via-she-bg/40 to-she-bg ----
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    V3Colors.background.withValues(alpha: 0.70),
                    V3Colors.background.withValues(alpha: 0.40),
                    V3Colors.background,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),

            // ---- Content ----
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  FadeTransition(
                    opacity: _logoController,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.82, end: 1.0).animate(
                        CurvedAnimation(
                          parent: _logoController,
                          curve: const Cubic(0.22, 1, 0.36, 1),
                        ),
                      ),
                      child: const _SplashWordmark(),
                    ),
                  ),
                  const Spacer(flex: 3),

                  // ---- Loading bar ----
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _barController,
                      curve: const Interval(0.5, 1.0),
                    ),
                    child: SizedBox(
                      width: 160,
                      child: Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              height: 4,
                              color: Colors.white.withValues(alpha: 0.10),
                              child: AnimatedBuilder(
                                animation: _barController,
                                builder: (context, _) => FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: _barController.value,
                                  child: Container(
                                    decoration:  BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          V3Colors.primary,
                                          V3Colors.successAlt,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            // Static English fallback: this string is read before
                            // the localization delegate is guaranteed to be ready.
                            'Loading',
                            style: TextStyle(
                              fontSize: V3Typography.meta,
                              color: V3Colors.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: V3Spacing.xxl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Glowing logo tile + "Smart Home Ethiopia" wordmark + "SHE" overline.
class _SplashWordmark extends StatelessWidget {
  const _SplashWordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: V3Colors.background.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: V3Colors.primary.withValues(alpha: 0.30),
            ),
            boxShadow: [
              BoxShadow(
                color: V3Colors.primary.withValues(alpha: 0.65),
                blurRadius: 60,
                spreadRadius: -8,
              ),
            ],
          ),
          child:  Icon(
            Icons.wifi_tethering,
            size: 44,
            color: V3Colors.primary,
          ),
        ),
        const SizedBox(height: 20),
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'Smart Home\n'),
              TextSpan(
                text: 'Ethiopia',
                style: TextStyle(color: V3Colors.primary),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 26,
            height: 1.15,
            fontWeight: FontWeight.w700,
            color: V3Colors.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'S H E',
          style: TextStyle(
            fontSize: V3Typography.meta,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.35 * V3Typography.meta,
            color: V3Colors.text2,
          ),
        ),
      ],
    );
  }
}
