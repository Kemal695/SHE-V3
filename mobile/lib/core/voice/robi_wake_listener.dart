// =============================================================================
// SHE V3 — Opens the voice screen when "Hey Robi" is heard (Phase 4, Stage 3;
// Phase 5 route decision moved to native RobiWakeListener.kt)
// =============================================================================
// The detector runs in a native service. As of Phase 5 (Plan §D.11 / §F.1) the
// ROUTE DECISION — "is the app foreground? open the voice screen vs. run
// headless" — lives in native Kotlin (RobiWakeListener.routeWake). This widget
// is now the EXECUTOR + a visibility safety net: it opens the screen for
// `open_voice` and runs the command headless for `hey_robi`. Command
// *interpretation* stays in Dart regardless (see MainActivity.kt's header).
//
// It deliberately does nothing when the app is not in the foreground: Android
// forbids starting an activity from the background, and pretending otherwise is
// how wake-word features end up lying about what they can do.
//
// It pushes `/voice?auto=1`, so the screen starts capturing on its own instead of
// asking the user to hold a button after they already spoke.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../routing/app_router.dart';
import '../network/active_home.dart';
import '../../features/voice/voice_service.dart';
import '../../features/robi/application/command_executor.dart';
import 'robi_wake.dart';
import '../../features/robi/data/robi_tts.dart';
import '../../features/robi/data/voice_diagnostics.dart';
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

  /// How many times a headless session has re-opened the mic because it heard
  /// only the wake-word tail. Reset on every fresh wake.
  int _headlessRetries = 0;

  static const int _maxHeadlessRetries = 1;

  /// When the last wake event arrived, to collapse the duplicate pair.
  ///
  /// Native emits BOTH `hey_robi` and `open_voice` for one utterance when the
  /// activity is paused but still visible — measured: "wake: native says
  /// background — running headless" and "wake: opening the voice screen" 5 ms
  /// apart. That starts a headless session AND a screen, i.e. two recognizers
  /// on one microphone; the session then never reports back and ends on the
  /// hard stop.
  DateTime? _lastWakeAt;

  static const Duration _duplicateWakeWindow = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    // Warm the TTS engine at app start so the first "Yes?" after a wake is not
    // delayed by TextToSpeech initialisation.
    unawaited(RobiTts.instance.warmUp());
    _sub = robiWake.events().listen((e) {
      final now = DateTime.now();
      if (e.event == 'open_voice') {
        // Native saw us in the foreground: show the voice screen.
        final recent = _lastWakeAt != null &&
            now.difference(_lastWakeAt!) < _duplicateWakeWindow;
        if (_headlessBusy || recent) {
          VoiceLog.log('wake: open_voice ignored — a session is already running');
          return;
        }
        _lastWakeAt = now;
        _openVoice();
        return;
      }
      if (e.event == 'hey_robi') {
        // Native already decided we are NOT foreground (screen locked / another
        // app in front). Go straight to headless: it updates Robi's notification
        // — now visible on the lock screen — and the service plays the "heard
        // you" beep. Re-deriving visibility from the Flutter lifecycle here was
        // wrong for a locked-but-`inactive` activity: it pushed the voice screen
        // behind the lock screen, so the user got no sign at all.
        VoiceLog.log('wake: native says background — running headless');
        _lastWakeAt = now;
        _headlessRetries = 0;
        unawaited(_runHeadless());
        return;
      }
    });
  }

  /// Open the voice screen and start listening immediately.
  ///
  /// Reached for `open_voice` (native saw us in the foreground) and a tap on
  /// Robi's notification. `hey_robi` — native saw us in the background — goes
  /// straight to [_runHeadless] instead, because a locked activity cannot show a
  /// window and pushing this route left the user with no feedback at all.
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
      _headlessRetries = 0;
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
    // Set when the session is over for ANY reason (result, onDone, watchdog).
    // The watchdog used to test `_headlessBusy`, which `finally` clears as soon
    // as startListening returns — so it never fired and a silent recognizer left
    // the session hanging forever.
    var finished = false;

    final service = ref.read(voiceServiceProvider);
    try {
      // Resolve the home CONCURRENTLY, never before the microphone opens.
      // Awaiting it here delayed the recognizer by a full API round-trip, and by
      // then the user had already said the command: the system log showed
      // "#onRecognitionFinished no speech - erroring" six times in a row on the
      // LE6, because the recognizer opened ~1 s after the wake word.
      const placeholderHome = '00000000-0000-0000-0000-000000000001';
      final homeFuture = resolveActiveHomeId(ref);
      VoiceLog.log('headless: listening');
      // Take the microphone from the detector BEFORE opening the recognizer.
      // Awaiting matters: onWake releases AudioRecord asynchronously, and
      // starting first means the recognizer can lose the mic and then never
      // report anything — which is exactly what left the notification stuck on
      // "Listening… say your command".
      await robiWake.pause();
      // Warm the context cache WHILE the user speaks, so the command executes
      // immediately when the transcript arrives.
      unawaited(homeFuture.then((id) => ref
          .read(commandExecutorProvider)
          .loadContext(id ?? placeholderHome)));
      // The notification now announces the session — the only feedback there is
      // when no window can be shown.
      unawaited(robiWake.notify('Listening… say your command'));

      // Watchdog for a session that never reports. The visible card has one;
      // without it here, a recognizer that loses the mic silently leaves the
      // notification stuck on "Listening… say your command" forever.
      _headlessWatchdog?.cancel();
      _headlessWatchdog = Timer(const Duration(seconds: 18), () async {
        if (finished) return;
        finished = true;
        handled = true;
        VoiceLog.log('headless: watchdog fired — no result');
        await service.cancel();
        await robiWake.notify("I didn't hear anything");
        await RobiTts.instance.speak("I didn't hear anything");
        await robiWake.resume();
        _headlessBusy = false;
      });

      // Speak the cue and let it FINISH before the microphone opens.
      //
      // The cue was previously spoken concurrently with listening, so the
      // recognizer transcribed our own "Yes?" and the tail of "Hey Robi" as part
      // of the command. Measured on the LE6 for "turn on socket 1 socket 2 and
      // light 1":
      //   heard="turn on socket one it's okay to in the light one"
      // i.e. "socket two and" came back as "it's okay to in", and Socket 2 was
      // never in the transcript at all. A fixed delay is used instead of waiting
      // for the engine's completion callback, which never fires on this device.
      // Only on the first attempt: retries used to say "Yes?" again, so the user
      // heard "yes, yes, yes" and never got a turn to speak.
      if (_headlessRetries == 0) {
        unawaited(RobiTts.instance.speak('Yes?'));
        unawaited(SystemSound.play(SystemSoundType.click));
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }

      await service.startListening(
        pushToTalk: false,
        fromWake: true,
        onResult: (text, isFinal, hypotheses) async {
          if (text.trim().isEmpty) return;

          // The wake tail is not a command. The keyword detector fires on the
          // phrase's last syllable, so the recognizer's first final is normally
          // "he's" / "it's okay" / "is it okay". Executing that answered
          // "I didn't understand it" and threw the session away — measured on the
          // LE6 for wake after wake. Ignore it and let the user finish speaking.
          if (isWakeEcho(text)) {
            VoiceLog.log('headless: wake echo "$text" — still listening');
            return;
          }

          if (!isFinal) return;
          handled = true;
          finished = true;
          VoiceLog.log('headless: heard "$text"');
          final homeId = await homeFuture ?? placeholderHome;
          final result = hypotheses.length > 1
              ? await service.handleUtterances(
                  hypotheses,
                  homeId: homeId,
                  latinDeviceTokens: true,
                )
              : await service.handleUtterance(
                  text,
                  homeId: homeId,
                  latinDeviceTokens: true,
                );
          VoiceLog.log('headless: ${result.message}');
          // Show what happened — the user cannot see the card. Speak the outcome
          // (success, "didn't understand", or a follow-up question), then let the
          // notification sit briefly before resume() replaces it with the armed
          // text.
          await robiWake.notify(result.message);
          await RobiTts.instance.speak(result.message);
          await Future<void>.delayed(const Duration(seconds: 2));
          await robiWake.resume();
        },
        onDone: () async {
          VoiceLog.log('headless: capture ended (handled=$handled)');
          if (finished) return;
          finished = true;
          _headlessWatchdog?.cancel();
          if (handled) return;
          // Nothing usable arrived — most often the recognizer ended the session
          // on the wake-word tail. Re-open the mic before giving up, so the user
          // does not have to repeat "Hey Robi".
          if (_headlessRetries < _maxHeadlessRetries) {
            _headlessRetries++;
            VoiceLog.log('headless: re-listening '
                '($_headlessRetries/$_maxHeadlessRetries)');
            await Future<void>.delayed(const Duration(milliseconds: 200));
            if (!mounted) return;
            unawaited(_runHeadless());
            return;
          }
          // Covers "the user said nothing": nothing else will resume the
          // detector, and without this the notification stayed on "listening
          // for your command" forever.
          await robiWake.notify('I didn\'t hear anything');
          await RobiTts.instance.speak('I didn\'t hear anything');
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
