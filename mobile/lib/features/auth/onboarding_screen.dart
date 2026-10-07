// =============================================================================
// SHE V3 — Onboarding (V3-UI-REDESIGN)
// =============================================================================
// Ported from the prototype's `Onboarding` panel (screens/auth.tsx): three
// slides with a Skip affordance, animated slide transitions, page dots, a
// Next / Get Started button, and an "I already have an account" escape hatch.
//
// Slide 1 and 3 are photo slides; slide 2 is the feature list (remote control,
// energy monitoring, automations) built from the SHECard-style rows.
//
// Shown once per install is NOT enforced here — the router sends an
// unauthenticated launch to /splash on every cold start, exactly like the
// prototype. Making it one-shot would need persistent settings and is
// deliberately out of scope.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../l10n/app_localizations.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  static const _slideCount = 3;

  final _pageController = PageController();
  late final AnimationController _anim;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _goToLogin() {
    // `go` (not push): once you leave onboarding there is no way back to it.
    context.go('/login');
  }

  void _next() {
    if (_index < _slideCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    } else {
      _goToLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    // `of()` is nullable because a delegate may not have loaded yet; the app
    // always installs one, so a null check here would be dead code.
    final l = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: V3Colors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ---- Skip ----
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: V3Spacing.md,
                  right: V3Spacing.lg,
                ),
                child: TextButton(
                  onPressed: _goToLogin,
                  style: TextButton.styleFrom(
                    foregroundColor: V3Colors.dim,
                    padding: const EdgeInsets.symmetric(
                      horizontal: V3Spacing.sm,
                      vertical: V3Spacing.xs,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    l.skip,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),

            // ---- Slides ----
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _PhotoSlide(
                    image: 'assets/img/home-dusk.png',
                    title: l.ob1Title,
                    body: l.ob1Body,
                  ),
                  _FeatureSlide(title: l.ob2Title, intro: l.ob2Intro, l: l),
                  _PhotoSlide(
                    image: 'assets/img/living-room.png',
                    title: l.ob3Title2,
                    body: l.ob3Body2,
                  ),
                ],
              ),
            ),

            // ---- Dots + actions ----
            Padding(
              padding: const EdgeInsets.fromLTRB(
                V3Spacing.xl,
                V3Spacing.sm,
                V3Spacing.xl,
                36,
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_slideCount, (i) {
                      final active = i == _index;
                      return GestureDetector(
                        onTap: () => _pageController.animateToPage(
                          i,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOut,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          height: 6,
                          width: active ? 24 : 6,
                          decoration: BoxDecoration(
                            color: active
                                ? V3Colors.primary
                                : Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 20),

                  // ---- Primary action ----
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: V3Colors.primary,
                        borderRadius: BorderRadius.circular(V3Radius.lg),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(V3Radius.lg),
                          onTap: _next,
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _index < _slideCount - 1
                                      ? l.next
                                      : l.getStarted,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: V3Colors.night,
                                  ),
                                ),
                                if (_index < _slideCount - 1) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.arrow_forward,
                                    size: 16,
                                    color: V3Colors.night,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ---- Escape hatch ----
                  TextButton(
                    onPressed: _goToLogin,
                    style: TextButton.styleFrom(
                      foregroundColor: V3Colors.text2,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: V3Spacing.sm,
                        vertical: V3Spacing.xs,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      l.haveAccount,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Slide 1 / 3 — photo + title + body
// -----------------------------------------------------------------------------
class _PhotoSlide extends StatelessWidget {
  const _PhotoSlide({
    required this.image,
    required this.title,
    required this.body,
  });

  final String image;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            V3Spacing.lg,
            V3Spacing.xs,
            V3Spacing.lg,
            0,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.42,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(
                      color: V3Colors.surface,
                      child: Center(
                        child: Icon(
                          Icons.image_outlined,
                          size: 40,
                          color: V3Colors.dim,
                        ),
                      ),
                    ),
                  ),
                  // from-she-bg/60 to-transparent
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          V3Colors.background.withValues(alpha: 0.60),
                          V3Colors.background.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: V3Spacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: V3Colors.ink,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: V3Colors.text2,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: V3Spacing.sm),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Slide 2 — feature list
// -----------------------------------------------------------------------------
class _FeatureSlide extends StatelessWidget {
  const _FeatureSlide({
    required this.title,
    required this.intro,
    required this.l,
  });

  final String title;
  final String intro;
  final AppLocalizations l;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 26,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: V3Colors.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            intro,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: V3Colors.text2,
            ),
          ),
          const SizedBox(height: V3Spacing.lg),
          _FeatureRow(
            icon: Icons.home_outlined,
            title: l.featRemote,
            body: l.featRemoteBody,
          ),
          const SizedBox(height: 14),
          _FeatureRow(
            icon: Icons.bolt_outlined,
            title: l.featEnergyM,
            body: l.featEnergyMBody,
          ),
          const SizedBox(height: 14),
          _FeatureRow(
            icon: Icons.account_tree_outlined,
            title: l.featAuto,
            body: l.featAutoBody,
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: V3Colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: V3Colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: V3Colors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: V3Colors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: V3Colors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    color: V3Colors.dim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
