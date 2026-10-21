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

import '../../routing/app_router.dart';
import '../network/active_home.dart';
import '../../features/voice/voice_service.dart';
import 'robi_wake.dart';
import 'voice_log.dart';

class RobiWakeListener extends ConsumerStatefulWidget {
  const RobiWakeListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RobiWakeListener> createState() => _RobiWakeListenerState();
}

class _RobiWakeListenerState extends ConsumerState<RobiWakeListener> {
  StreamSubscription<({String event, String? detail})>? _sub;

  /// Guards against a second wake starting a second headless session.
  bool _headlessBusy = false;

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
    final visible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;

    if (!visible) {
      // Screen off, locked, or another app in front. Android will not let us
      // show a window, but it does not stop our code from running: the
      // foreground service keeps this process alive, so the whole command runs
      // headless — listen, parse, execute — with no UI at all. That is what
      // makes "turn on the light" work with the phone in your pocket.
      VoiceLog.log('wake: app is $state — running headless');
      unawaited(_runHeadless());
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

  /// Run the whole command with no UI.
  ///
  /// Used when the app is not visible — screen off, locked, or another app in
  /// front. There is no screen to draw on, but the process is alive (the
  /// foreground service keeps it that way), so the recognizer and the command
  /// engine work exactly as they do on screen.
  Future<void> _runHeadless() async {
    if (_headlessBusy) return;
    _headlessBusy = true;

    final service = ref.read(voiceServiceProvider);
    try {
      final homeId = await resolveActiveHomeId(ref) ??
          '00000000-0000-0000-0000-000000000001';
      VoiceLog.log('headless: listening');

      await service.startListening(
        pushToTalk: false,
        fromWake: true,
        onResult: (text, isFinal) async {
          if (!isFinal || text.trim().isEmpty) return;
          VoiceLog.log('headless: heard "$text"');
          final result = await service.handleUtterance(
            text,
            homeId: homeId,
            latinDeviceTokens: true,
          );
          // No screen to show this on; the light changing is the feedback, and
          // the log is how we verify it.
          VoiceLog.log('headless: ${result.message}');
          // The command is done — give the microphone back to the detector.
          // Without this the notification stayed on "listening for your
          // command" forever, because only the VISIBLE card ever called resume().
          await robiWake.resume();
        },
        onDone: () async {
          VoiceLog.log('headless: capture ended');
          // Also covers "the user said nothing": the session is over either way.
          await robiWake.resume();
        },
      );
    } catch (e) {
      VoiceLog.log('headless: failed — $e');
    } finally {
      _headlessBusy = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
