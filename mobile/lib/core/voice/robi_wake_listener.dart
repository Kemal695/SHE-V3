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
import 'wake_phrase.dart';

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

  /// Hard stop for a headless session that never reports.
  Timer? _headlessWatchdog;

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
    // Set once a final transcript has been handled, so onDone knows whether to
    // report "didn't hear anything" or stay quiet.
    var handled = false;

    final service = ref.read(voiceServiceProvider);
    try {
      final homeId = await resolveActiveHomeId(ref) ??
          '00000000-0000-0000-0000-000000000001';
      VoiceLog.log('headless: listening');
      // Take the microphone from the detector BEFORE opening the recognizer.
      // Awaiting matters: onWake releases AudioRecord asynchronously, and
      // starting first means the recognizer can lose the mic and then never
      // report anything — which is exactly what left the notification stuck on
      // "Listening… say your command".
      await robiWake.pause();
      // The notification now announces the session — the only feedback there is
      // when no window can be shown.
      unawaited(robiWake.notify('Listening… say your command'));

      // Watchdog for a session that never reports. The visible card has one;
      // without it here, a recognizer that loses the mic silently leaves the
      // notification stuck on "Listening… say your command" forever.
      _headlessWatchdog?.cancel();
      _headlessWatchdog = Timer(const Duration(seconds: 18), () async {
        if (handled || !_headlessBusy) return;
        handled = true;
        VoiceLog.log('headless: watchdog fired — no result');
        await service.cancel();
        await robiWake.notify("I didn't hear anything");
        await robiWake.resume();
        _headlessBusy = false;
      });

      await service.startListening(
        pushToTalk: false,
        fromWake: true,
        onResult: (text, isFinal) async {
          if (text.trim().isEmpty) return;

          // Barge-in on a PARTIAL result — the user is still speaking, so this
          // aborts mid-utterance rather than after they finish. Partials repeat
          // for the same utterance, hence the `handled` guard.
          if (isWakePhrase(text)) {
            if (handled) return;
            handled = true;
            VoiceLog.log('headless: barge-in — aborting the command');
            await service.cancel();
            await robiWake.notify('Okay — say "Hey Robi" again');
            await robiWake.resume();
            return;
          }

          if (!isFinal) return;
          handled = true;
          VoiceLog.log('headless: heard "$text"');
          final result = await service.handleUtterance(
            text,
            homeId: homeId,
            latinDeviceTokens: true,
          );
          VoiceLog.log('headless: ${result.message}');
          // Show what happened — the user cannot see the card. Held for a few
          // seconds so it is readable, then the notification returns to its
          // armed text when the detector resumes.
          await robiWake.notify(result.message);
          await Future<void>.delayed(const Duration(seconds: 4));
          await robiWake.resume();
        },
        onDone: () async {
          VoiceLog.log('headless: capture ended (handled=$handled)');
          // Covers "the user said nothing": nothing else will resume the
          // detector, and without this the notification stayed on "listening
          // for your command" forever.
          if (handled) return;
          await robiWake.notify('I didn\'t hear anything');
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
    _headlessWatchdog?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
