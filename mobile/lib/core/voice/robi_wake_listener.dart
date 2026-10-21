// =============================================================================
// SHE V3 — Opens the voice screen when "Hey Robi" is heard (Phase 4, Stage 3)
// =============================================================================
// The detector runs in a native service; this widget is the only place that
// turns a detection into UI. It deliberately does nothing when the app is not in
// the foreground: Android forbids starting an activity from the background, and
// pretending otherwise is how wake-word features end up lying about what they
// can do.
//
// It pushes `/voice?auto=1`, so the screen starts capturing on its own instead of
// asking the user to hold a button after they already spoke.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'robi_wake.dart';
import 'voice_log.dart';
import '../../routing/app_router.dart';

class RobiWakeListener extends ConsumerStatefulWidget {
  const RobiWakeListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RobiWakeListener> createState() => _RobiWakeListenerState();
}

class _RobiWakeListenerState extends ConsumerState<RobiWakeListener> {
  StreamSubscription<({String event, String? detail})>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = robiWake.events().listen((e) {
      if (e.event == 'hey_robi' || e.event == 'open_voice') {
        _openVoice();
        return;
      }
    });
  }

  /// Open the voice screen and start listening immediately.
  ///
  /// Two triggers: the wake word (`hey_robi`) and a tap on Robi's notification
  /// (`open_voice`). Both end up here, so there is one handoff to maintain.
  void _openVoice() {
    if (!mounted) return;

    // `inactive` is NOT a reason to refuse. It means the app is visible but not
    // focused — the notification shade pulled down, a dialog, a system overlay.
    // Requiring `resumed` blocked exactly that case, and the log showed wake
    // after wake dying here: "wake: app not resumed (AppLifecycleState.inactive)".
    // Only a genuinely backgrounded app (paused/hidden/detached) cannot start an
    // activity, and Android forbids that anyway.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive) {
      VoiceLog.log('wake: app is $state — cannot open the screen');
      return;
    }

    // Ignore a second activation while the voice screen is already open —
    // pushing twice would stack two screens and two microphone clients.
    final router = ref.read(appRouterProvider);
    final location = router.routerDelegate.currentConfiguration.uri.path;
    if (location == '/voice') return;

    VoiceLog.log('wake: opening the voice screen');
    router.push('/voice?auto=1&compact=1');
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
