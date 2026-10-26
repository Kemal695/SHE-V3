// =============================================================================
// SHE V3 — Voice Control Screen (phone-side)
// =============================================================================
// V3-VOICE-MATTER §1-2.
//
// This screen used to be a mockup: tapping the mic flipped a local boolean and
// printed 'Listening for "Hey Sheba"...' without opening a microphone or calling
// anything. It now drives a real recognizer and executes the parsed command
// against the same REST API the rest of the app uses.
//
// The firmware Picovoice path (on-device wake word, R16 only) is still Phase 4C
// and unrelated to this file — see voice_service.dart's header for why this
// approach was chosen instead.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemSound, SystemSoundType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../../core/voice/robi_wake.dart';
import '../robi/application/command_executor.dart';
import '../robi/data/robi_tts.dart';
import '../robi/data/voice_diagnostics.dart';
import '../../core/voice/wake_phrase.dart';
import '../device_detail/node_service.dart';
import 'voice_intent.dart';
import 'voice_service.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key, this.autoStart = false, this.compact = false});

  /// Start capturing as soon as the screen opens.
  ///
  /// Set when the screen is opened by the wake word ("Hey Robi"): the user has
  /// already spoken, so making them hold a button would waste the activation.
  final bool autoStart;

  /// Render as a small floating card instead of a full page (wake-word mode).
  final bool compact;

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  VoicePhase _phase = VoicePhase.initializing;
  String? _transcript;

  /// Every hypothesis the recognizer offered for the current utterance, best
  /// first. Parsed together so a mangled top guess does not lose the command.
  List<String> _lastHypotheses = const [];
  VoiceIntent? _intent;
  String? _message;
  String _homeId = '00000000-0000-0000-0000-000000000001';

  /// True between pointer-down and the recognizer actually being live.
  ///
  /// Push-to-talk makes a fast press/release possible, and `stop()` on a
  /// recognizer that has not finished starting is a no-op — so without this the
  /// utterance would be silently dropped. The release handler checks it and
  /// cancels once startup completes.
  bool _starting = false;

  /// Set when the user lets go before the recognizer came up.
  bool _releasePending = false;

  /// True when the wake word opened this session (no button to release).
  bool _wakeSession = false;

  /// Set when the user pressed "Stop listening", so the UI can say so instead of
  /// claiming nothing was heard.
  bool _userStopped = false;

  /// Guards the partial-result barge-in against restarting twice for the same
  /// utterance (partials arrive repeatedly).
  bool _bargingIn = false;

  /// How many times a wake session has re-opened the recognizer because its
  /// final was only the tail of "Hey Robi" (see [isWakeEcho]).
  ///
  /// The keyword detector fires on the LAST syllable of the phrase, so the
  /// recognizer opens ~200 ms later and its first final is usually the tail
  /// ("he's", "hey", "yes"). Acting on that ended the session before the user
  /// had even started their command — measured on the LE6 as
  /// `recognizerFinal="he's"` followed by "I didn't understand it". Bounded at
  /// [_maxWakeRetries] so a noisy room cannot hold the microphone open.
  int _wakeRetries = 0;

  static const int _maxWakeRetries = 1;

  /// Hard stop for a wake session.
  ///
  /// `listenFor` should end the session on its own, but when the microphone is
  /// taken away mid-session (another client, or the wake detector re-arming)
  /// the recognizer never calls back and the screen sits on "Listening…"
  /// forever. This guarantees the UI returns to a usable state.
  Timer? _sessionWatchdog;

  /// Backstop for a recognizer that never calls back.
  ///
  /// [_sessionWatchdog] only covers the UI; this one FORCE-CANCELS the
  /// recognizer, because on this device `SpeechListenOptions.listenFor` is not
  /// honoured (measured: 17-minute sessions that never released the mic).
  Timer? _hardStop;

  /// Last few pipeline events, shown on screen (see the diagnostics block).
  final List<String> _diag = [];

  /// Record a stage for both logcat and the on-screen diagnostics.
  void _stage(String message) {
    VoiceLog.log(message);
    if (!mounted) return;
    setState(() {
      _diag.add(message);
      if (_diag.length > 4) _diag.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _sessionWatchdog?.cancel();
    _hardStop?.cancel();
    // Hand the mic back so the wake word works again after this screen closes.
    unawaited(robiWake.resume());
    _pulseController.dispose();
    // Leaving the screen must release the mic — a recognizer left running keeps
    // the Android mic indicator on and burns battery.
    ref.read(voiceServiceProvider).cancel();
    super.dispose();
  }

  /// Resolve the real home id in the BACKGROUND.
  ///
  /// Never awaited before the microphone opens: it is an API call, and the user
  /// is already speaking by the time it returns (the LE6 log showed the
  /// recognizer opening ~1 s after the wake word and reporting "no speech").
  Future<void> _resolveHome() async {
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (homes.isNotEmpty) {
        // Same defensive shape as provisioning_screen: the id key has appeared
        // as both `id` and `home_id` across backends, and a hard cast here
        // would throw and silently kill device commands.
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) _homeId = id;
      }
    } catch (_) {
      // Keep the placeholder home — it is the tenant id, and commands still work.
    }
  }

  Future<void> _bootstrap() async {
    final availability = await ref.read(voiceAvailabilityProvider.future);
    if (!mounted) return;
    setState(() {
      _phase = availability.available ? VoicePhase.idle : VoicePhase.unavailable;
      _message = availability.reason;
    });

    // Opened by the wake word: open the microphone FIRST, in sentence mode (not
    // push-to-talk — there is no finger to hold), then resolve the home while
    // the user is still speaking.
    if (widget.autoStart && availability.available) {
      _wakeRetries = 0;
      unawaited(_resolveHome());
      await _startListening(pushToTalk: false);
      return;
    }
    await _resolveHome();
  }

  bool get _listening => _phase == VoicePhase.listening;

  /// Records until the finger lifts (push-to-talk), or until the sentence
  /// finishes when [pushToTalk] is false (wake-word activation).
  ///
  Future<void> _startListening({bool pushToTalk = true}) async {
    if (_phase == VoicePhase.unavailable ||
        _phase == VoicePhase.executing ||
        _listening ||
        _starting) {
      return;
    }

    final service = ref.read(voiceServiceProvider);

    setState(() {
      _phase = VoicePhase.listening;
      _transcript = null;
      _intent = null;
      _message = null;
      _releasePending = false;
      _wakeSession = !pushToTalk;
      // A finger on the mic is a fresh intent to speak: the echo allowance from
      // a previous wake session must not carry over.
      if (pushToTalk) _wakeRetries = 0;
    });
    _pulseController.repeat(reverse: true);

    // Audible cue that the microphone is open. Without it there is no way to
    // know when to start speaking — the screen appearing is not a cue, and the
    // silence timeout then expires with nothing said.
    unawaited(SystemSound.play(SystemSoundType.click));
    _stage('capture: started (${pushToTalk ? 'push-to-talk' : 'wake'})');

    // Watchdog: never leave the screen stuck on "Listening…".
    _sessionWatchdog?.cancel();
    if (!pushToTalk) {
      _sessionWatchdog = Timer(const Duration(seconds: 18), () {
        if (!mounted || !_listening) return;
        _stage('capture: watchdog fired — no result');
        ref.read(voiceServiceProvider).cancel();
        unawaited(robiWake.resume());
        _pulseController.stop();
        setState(() {
          _phase = VoicePhase.idle;
          _message = "I didn't hear anything — tap the mic and try again.";
        });
      });
    }

    _starting = true;
    _stage('capture: start (pushToTalk=$pushToTalk fromWake=${!pushToTalk})');
    // Backstop: force the recognizer shut if it never reports back. The plugin's
    // own listenFor is NOT honoured on this device, so this is the real cap.
    _hardStop?.cancel();
    _hardStop = Timer(const Duration(seconds: 12), () {
      if (!mounted || _phase != VoicePhase.listening) return;
      _stage('capture: hard stop — recognizer never reported back');
      ref.read(voiceServiceProvider).cancel();
      unawaited(robiWake.resume());
      _pulseController.stop();
      setState(() {
        _phase = VoicePhase.idle;
        _message = _userStopped
            ? 'Stopped. Tap the mic when you are ready.'
            : "I didn't catch that — tap the mic and try again.";
      });
      _userStopped = false;
    });
    try {
      // Take the microphone from the wake detector BEFORE opening the
      // recognizer. Awaiting matters: the detector releases AudioRecord
      // asynchronously, and starting the recognizer first lost the mic. Bounded,
      // because a wedged native service must never be able to block the mic.
      await robiWake.pause().timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            _stage('capture: robiWake.pause() timed out — continuing'),
      );
      // Warm the context cache WHILE the user speaks so the command can execute
      // the instant the transcript arrives (loadContext used to run only AFTER
      // the utterance, adding seconds of latency).
      unawaited(ref.read(commandExecutorProvider).loadContext(_homeId));
      // Wake cue. Spoken CONCURRENTLY (not awaited) so the microphone opens
      // immediately — waiting for the TTS added ~0.5-1 s to every wake and
      // clipped the user's first word. The parser ignores the extra "Yes?" if
      // the recognizer hears it. Push-to-talk stays silent (the button is the
      // cue).
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
      if (!pushToTalk && _wakeRetries == 0) {
        unawaited(RobiTts.instance.speak('Yes?'));
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
      await service.startListening(
        // Push-to-talk: the finger lifting ends the recording, not silence.
        // Wake-word mode passes false so the sentence decides.
        pushToTalk: pushToTalk,
        // The wake word opened this screen: give the user time to speak.
        fromWake: !pushToTalk,
        onResult: (text, isFinal, hypotheses) {
          if (!mounted) return;
          setState(() => _transcript = text);
          // Keep every hypothesis so the parse can pick the best one.
          _lastHypotheses = hypotheses;

          // Barge-in on a PARTIAL result. The recognizer streams partials while
          // the user is still speaking (partialResults: true), so checking here
          // aborts mid-utterance instead of waiting for them to finish — which
          // is what "some times i miss command" actually needs. Partials repeat,
          // hence the guard.
          if (!isFinal && isWakePhrase(text)) {
            _bargeIn();
            return;
          }
          if (isFinal) {
            // Logged BEFORE anything else so the raw recognizer output is always
            // in the log, even if the parse or the session later misbehaves.
            VoiceLog.log('recognizerFinal="$text" wake=$_wakeSession');
            // The wake word fires on its last syllable, so the first final of a
            // wake session is usually just that tail. Ending here is what made
            // "turn on socket 1 socket 2 and light 1" and "is socket 2 on" look
            // broken: the command was never in the transcript.
            if (_wakeSession &&
                _wakeRetries < _maxWakeRetries &&
                isWakeEcho(text)) {
              unawaited(_relisten('wake echo "$text"'));
              return;
            }
            _finish(text, hypotheses: hypotheses);
          }
        },
        onDone: () {
          // Distinguishes "the session ended with no transcript" from "the
          // session never ended" — the two look identical in the UI.
          _hardStop?.cancel();
          _stage('capture: ended (final=${_transcript ?? '<none>'})');
          if (!mounted) return;
          // Ignore a stale session's end while a barge-in restart is in flight:
          // the OLD onDone can land after the NEW session has set `listening`,
          // and acting on its leftover partial would run the wrong command.
          if (_phase == VoicePhase.listening && !_bargingIn) {
            // The recognizer can end the session WITHOUT delivering a FINAL
            // result — a known dictation-mode quirk on some devices, and the
            // normal outcome when only partials arrived before the silence
            // timeout. `_phase` is still `listening` here, so no final was
            // processed. Running what we DID hear is far better than discarding
            // it and leaving the user staring at "Listening…" until the 15 s cap
            // or the 18 s watchdog fires — that was the "stuck waiting for my
            // command even after I finished" bug.
            final heard = _transcript?.trim() ?? '';
            if (heard.isNotEmpty) {
              // Same echo rule as the final path: a session that ended on the
              // wake-word tail has not heard a command yet.
              if (_wakeSession &&
                  _wakeRetries < _maxWakeRetries &&
                  isWakeEcho(heard)) {
                unawaited(_relisten('wake echo "$heard"'));
                return;
              }
              _stage('capture: ended without final — running the transcript');
              _finish(heard, hypotheses: _lastHypotheses);
              return;
            }
            // Nothing at all: the recognizer errored (no speech / no match) or
            // the user released before speaking. In a wake session, re-open the
            // mic once instead of leaving them with the 12 s "Listening…" hang
            // that reads as "stuck".
            if (_wakeSession &&
                !_userStopped &&
                _wakeRetries < _maxWakeRetries) {
              unawaited(_relisten('nothing heard'));
              return;
            }
            setState(() {
              _phase = VoicePhase.idle;
              _message = _userStopped
                  ? 'Stopped. Tap the mic when you are ready.'
                  : "I didn't hear anything — tap the mic and try again.";
            });
            _userStopped = false;
            _pulseController.stop();
          }
        },
      );
      _stage('capture: recognizer is live');
    } finally {
      _starting = false;
    }

    // The finger came up while the recognizer was still starting, so the release
    // handler could not act. Stop now that it is live, or we would record until
    // the 12 s cap.
    if (_releasePending) {
      _releasePending = false;
      await _stopListening();
    }
  }

  /// Called on pointer-up / pointer-cancel. Finalizing here (rather than letting
  /// the recognizer time out) is the whole point of push-to-talk: `stop()`
  /// flushes the last partial result as final, so a short command is sent the
  /// instant the button is released.
  Future<void> _stopListening({bool explicit = false}) async {
    if (_starting) {
      // Recognizer not live yet — remember it and let _startListening finish.
      _releasePending = true;
      return;
    }
    if (!_listening) return;
    if (explicit) _userStopped = true;

    _pulseController.stop();
    await ref.read(voiceServiceProvider).stopListening();
  }

  /// Abort the current capture because the user said the wake phrase again.
  ///
  /// Called from a PARTIAL result, i.e. while they are still speaking. Partials
  /// arrive repeatedly for the same utterance, so [_bargingIn] stops a second
  /// restart before the first one has taken effect.
  void _bargeIn() {
    if (_bargingIn || !_listening) return;
    _bargingIn = true;
    _stage('barge-in: restarting');
    ref.read(voiceServiceProvider).cancel();
    _sessionWatchdog?.cancel();
    setState(() {
      _phase = VoicePhase.idle;
      _message = 'Restarted — say your command';
      _transcript = null;
      _intent = null;
    });
    unawaited(
      _startListening(pushToTalk: false).whenComplete(() => _bargingIn = false),
    );
  }

  /// Re-open the microphone for one more try.
  ///
  /// Covers both failure modes seen on the LE6: the session ended on the wake
  /// word's tail ("he's", "it's okay") — see [isWakeEcho] — and the session ended
  /// with nothing at all because the recognizer errored (the system log says
  /// "#onRecognitionFinished no speech - erroring"). Re-opening beats making the
  /// user say "Hey Robi" again.
  Future<void> _relisten(String why) async {
    _wakeRetries++;
    _stage('$why — listening again ($_wakeRetries/$_maxWakeRetries)');
    _sessionWatchdog?.cancel();
    _hardStop?.cancel();
    ref.read(voiceServiceProvider).cancel();
    // Let the last syllable decay so it is not captured a second time.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    setState(() {
      _phase = VoicePhase.idle;
      _transcript = null;
      _message = 'Listening…';
    });
    await _startListening(pushToTalk: false);
  }

  Future<void> _finish(String transcript,
      {List<String> hypotheses = const []}) async {
    _sessionWatchdog?.cancel();
    _pulseController.stop();

    // Nothing but the wake phrase, even after the retries in the result handler
    // were used up. Restarting here would loop forever on a noisy room, and
    // running it would answer "I didn't understand 'he's'". Say so plainly and
    // hand the microphone back to the wake detector.
    //
    // Note this is [isWakeEcho], not [isWakePhrase]: "hey robi turn on socket 1"
    // contains the phrase AND a command, and must be executed, not restarted.
    if (isWakeEcho(transcript)) {
      VoiceLog.log('finish: only the wake echo "$transcript" — not a command');
      ref.read(voiceServiceProvider).cancel();
      if (mounted) {
        setState(() {
          _phase = VoicePhase.idle;
          _transcript = null;
          _intent = null;
          _message = "I didn't catch that — try again.";
        });
      }
      unawaited(robiWake.resume());
      return;
    }
    if (!mounted) return;
    setState(() => _phase = VoicePhase.executing);

    final service = ref.read(voiceServiceProvider);
    try {
      // Several hypotheses: let the brain pick the one that parses. The top
      // hypothesis is often mangled while a lower-ranked one names real devices.
      final result = hypotheses.length > 1
          ? await service.handleUtterances(
              hypotheses,
              homeId: _homeId,
              latinDeviceTokens: !service.transcriptIsAmharic,
            )
          : await service.handleUtterance(
              transcript,
              homeId: _homeId,
              // Only trust Latin device tokens when the recognizer is actually
              // Latin; see voice_intent.dart's header for why this is a guard.
              latinDeviceTokens: !service.transcriptIsAmharic,
            );
      if (!mounted) return;
      setState(() {
        _intent = result.intent;
        _message = result.message;
        _phase = result.intent.isUnknown ? VoicePhase.error : VoicePhase.done;
      });
      // Speak the outcome — the action taken, "didn't understand", or a
      // follow-up question. Fire-and-forget so the UI updates immediately.
      unawaited(RobiTts.instance.speak(result.message));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = VoicePhase.error;
        _message = 'Command failed: $e';
      });
      unawaited(RobiTts.instance.speak('Sorry, that failed.'));
    } finally {
      // The command is finished, so the microphone is free again. Resuming here
      // (not only on dispose) keeps the notification honest — it used to sit on
      // "In a conversation…" for as long as the card stayed open.
      unawaited(robiWake.resume());
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = _buildFull(context);
    if (!widget.compact) return full;

    // Compact mode (wake word): the assistant card from the design sheet —
    // Listening → Responding → Done — instead of a whole settings-style page.
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.6),
      body: Center(
        child: Container(
          width: 320,
          height: 430,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: V3Colors.background,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: V3Colors.primary.withValues(alpha: 0.35),
            ),
            boxShadow: [
              BoxShadow(
                color: V3Colors.primary.withValues(alpha: 0.30),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
          ),
          child: _compactBody(context),
        ),
      ),
    );
  }

  /// The three states of the assistant card (design sheet, page 2).
  Widget _compactBody(BuildContext context) {
    final listening = _phase == VoicePhase.listening;
    final done = _phase == VoicePhase.done;
    final working = _phase == VoicePhase.executing;
    final failed = _phase == VoicePhase.error;

    // Every device named, so "socket 1 and light 2" shows both.
    final device = _intent == null || _intent!.devices.isEmpty
        ? null
        : _intent!.devices.map((d) => d.label).join(', ');

    return Padding(
      padding: const EdgeInsets.all(V3Spacing.lg),
      child: Column(
        children: [
          // ---- Close -------------------------------------------------------
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              icon:  Icon(Icons.close, color: V3Colors.textSecondary),
              onPressed: () => context.pop(),
            ),
          ),

          const Spacer(),

          // ---- Pulsing ring ------------------------------------------------
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              final t = listening ? _pulseController.value : 0.0;
              return Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: V3Colors.primary.withValues(alpha: 0.08),
                  border: Border.all(
                    color: V3Colors.primary.withValues(alpha: 0.35 + 0.4 * t),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: V3Colors.primary.withValues(alpha: 0.18 + 0.22 * t),
                      blurRadius: 28 + 14 * t,
                      spreadRadius: 2 + 6 * t,
                    ),
                  ],
                ),
                child: Icon(
                  done
                      ? Icons.check
                      : failed
                          ? Icons.error_outline
                          : Icons.mic,
                  size: 52,
                  color: failed
                      ? V3Colors.error
                      : done
                          ? V3Colors.success
                          : V3Colors.primary,
                ),
              );
            },
          ),

          const SizedBox(height: V3Spacing.lg),

          // ---- Title -------------------------------------------------------
          Text(
            listening
                ? 'Listening…'
                : working
                    ? 'Working…'
                    : done
                        ? 'Done!'
                        : failed
                            ? 'Sorry'
                            : 'Robi',
            style: TextStyle(
              color: V3Colors.ink,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),

          const SizedBox(height: 6),

          // ---- Subtitle / what it heard or did ------------------------------
          Text(
            listening
                ? (_wakeSession ? 'Say your command' : 'Speak now')
                : (_message ?? (done ? 'Done' : '')),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: V3Colors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),

          // ---- Stop listening ----------------------------------------------
          // Background noise never looks like silence, so the recognizer can
          // hold the mic until its listenFor cap. Always offer a way out.
          if (listening) ...[
            const SizedBox(height: V3Spacing.md),
            OutlinedButton.icon(
              onPressed: () => _stopListening(explicit: true),
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop listening'),
              style: OutlinedButton.styleFrom(
                foregroundColor: V3Colors.textSecondary,
                side: BorderSide(
                  color: V3Colors.textSecondary.withValues(alpha: 0.4),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: V3Spacing.md,
                  vertical: 10,
                ),
              ),
            ),
          ],

          // ---- Device chip (design sheet: "Living Room Lights · ON · 70%") --
          if (done && device != null) ...[
            const SizedBox(height: V3Spacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: V3Colors.surface,
                borderRadius: BorderRadius.circular(V3Radius.md),
                border: Border.all(
                  color: V3Colors.primary.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lightbulb, size: 18, color: V3Colors.warning),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      device,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: V3Colors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const Spacer(),

          // ---- Footer: another command, or the wake-word hint --------------
          if (done)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // Start listening again rather than returning to an idle screen
                // with no mic button — the card has no button to press.
                onPressed: () => _startListening(pushToTalk: false),
                icon:  Icon(Icons.mic_none, size: 18),
                label: const Text('Say another command'),
              ),
            )
          else
            Text(
              'Listening for your wake word…',
              style: TextStyle(color: V3Colors.dim, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _buildFull(BuildContext context) {
    final availability = ref.watch(voiceAvailabilityProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon:  Icon(Icons.arrow_back, color: V3Colors.textPrimary),
          // In compact mode this is a dismiss, not a jump to the dashboard —
          // the user came from another app and should land back in it.
          onPressed: () =>
              widget.compact ? context.pop() : context.go('/dashboard'),
        ),
        title: const Text('Voice Control'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'My commands',
            onPressed: () => context.push('/custom-commands'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(V3Spacing.lg),
          children: [
            const SizedBox(height: V3Spacing.md),

            // ---- Pulsing mic (push-to-talk) ----
            Center(
              child: Listener(
                // Raw pointer events rather than GestureDetector taps: this sits
                // inside a ListView, and a tap gesture is claimed by the scroll
                // arena as soon as the finger drifts a few pixels — which would
                // cancel the recording mid-sentence. Push-to-talk only cares
                // about down → up, so bypass the gesture arena entirely.
                onPointerDown: (_) => _startListening(),
                onPointerUp: (_) => _stopListening(),
                onPointerCancel: (_) => _stopListening(),
                child: AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, _) {
                    final t = _listening ? _pulseController.value : 0.0;
                    return Transform.scale(
                      scale: 1.0 + t * 0.12,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _listening ? V3Colors.primary : V3Colors.surface,
                          boxShadow: _listening
                              ? [
                                  BoxShadow(
                                    color: V3Colors.primary
                                        .withValues(alpha: 0.3 + t * 0.2),
                                    blurRadius: 30 + t * 20,
                                    spreadRadius: 5 + t * 10,
                                  ),
                                ]
                              : [],
                        ),
                        child: Icon(
                          _listening ? Icons.mic : Icons.mic_none,
                          size: 48,
                          color:
                              _listening ? Colors.white : V3Colors.textSecondary,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: V3Spacing.lg),

            // ---- Status line (real state, not decoration) ----
            Center(
              child: Text(
                _statusText(),
                style: TextStyle(
                  color: _listening ? V3Colors.primary : V3Colors.textSecondary,
                  fontSize: V3Typography.bodySize,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            // ---- On-screen diagnostics ----
            // The pipeline has several stages (wake → session → mic → transcript →
            // parse → execute) and a failure looks identical from the outside. These
            // are the last few events, so the phone itself says where it stopped —
            // no adb, no guessing, no "it didn't work".
            if (_diag.isNotEmpty) ...[
              const SizedBox(height: V3Spacing.sm),
              Text(
                _diag.join('\n'),
                style: TextStyle(
                  color: V3Colors.dim,
                  fontSize: 11,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],

            // ---- Live transcript ----
            if (_transcript != null && _transcript!.trim().isNotEmpty) ...[
              const SizedBox(height: V3Spacing.md),
              _panel(
                icon: Icons.hearing,
                iconColor: V3Colors.textSecondary,
                title: 'Heard',
                body: _transcript!,
                bodyIsPrimary: true,
              ),
            ],

            // ---- Parsed intent / outcome ----
            if (_message != null) ...[
              const SizedBox(height: V3Spacing.md),
              _panel(
                icon: _phase == VoicePhase.error
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                iconColor: _phase == VoicePhase.error
                    ? V3Colors.error
                    : V3Colors.success,
                title: _phase == VoicePhase.error ? 'Problem' : 'Understood',
                body: _message!,
                extra: _intent != null && !_intent!.isUnknown
                    ? '${_intent!.describe()}  ·  '
                        '${(_intent!.confidence * 100).round()}% sure'
                    : null,
              ),
              // When nothing was understood, show what Robi DOES take, so the
              // user is not guessing.
              if (_intent != null && _intent!.isUnknown) ...[
                const SizedBox(height: V3Spacing.sm),
                _panel(
                  icon: Icons.lightbulb_outline,
                  iconColor: V3Colors.primary,
                  title: 'Try saying',
                  body: 'turn on socket 1 · turn off light 2 · '
                      'switch on socket 1 · turn on the living room',
                ),
              ],
            ],

            const SizedBox(height: V3Spacing.lg),

            // ---- Locale honesty ----
            // Amharic is the app's default locale, but Android has no `am`
            // locale code, so on many phones we cannot recognize Ethiopic. Say so
            // rather than silently listening for a language the user isn't speaking.
            availability.maybeWhen(
              data: (a) => a.amharicUnsupported
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: V3Spacing.md),
                      child: _panel(
                        icon: Icons.translate,
                        iconColor: V3Colors.warning,
                        title: 'Amharic may not be supported',
                        body: a.reason ??
                            'This phone does not list an Amharic recognizer. '
                                'Robi will still try; if nothing is understood, '
                                'install an Amharic speech pack or switch the '
                                'app to English.',
                      ),
                    )
                  : const SizedBox.shrink(),
              orElse: () => const SizedBox.shrink(),
            ),

            // ---- Examples ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(V3Spacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                     Row(
                      children: [
                        Icon(Icons.lightbulb_outline,
                            color: V3Colors.warning, size: 20),
                        const SizedBox(width: V3Spacing.sm),
                        Text('Example Commands',
                            style: TextStyle(
                              color: V3Colors.textPrimary,
                              fontSize: V3Typography.titleSize - 2,
                              fontWeight: FontWeight.w600,
                            )),
                      ],
                    ),
                    const SizedBox(height: V3Spacing.md),

                    // Amharic first, matching the app's default locale. These are
                    // the phrasings the parser actually handles.
                    _sectionLabel('አማርኛ'),
                    _commandRow('መብራት አብር', 'all lights on'),
                    _commandRow('ሁሉም መብራት አጥፋ', 'all lights off'),
                    _commandRow('ሁሉም ሶኬት አጥፋ', 'all sockets off'),
                    _commandRow('ሳሎን መብራት አብር', 'a renamed device'),

                    const SizedBox(height: V3Spacing.md),
                    _sectionLabel('English'),
                    _commandRow('turn off light 1', 'one relay'),
                    _commandRow('light 1 on', 'no "turn" needed'),
                    _commandRow('turn off all the lights', 'the whole class'),
                    _commandRow('close socket 3', 'sockets too'),
                  ],
                ),
              ),
            ),

            const SizedBox(height: V3Spacing.md),

            // ---- What this actually is ----
            _panel(
              icon: Icons.info_outline,
              iconColor: V3Colors.textSecondary,
              title: 'How this works',
              body: 'Recognition runs on this phone, then the command goes to '
                  'your board over the same API the app uses. So it works on '
                  'every model — including the R24, which has no microphone.',
            ),
          ],
        ),
      ),
    );
  }

  String _statusText() {
    return switch (_phase) {
      VoicePhase.initializing => 'Checking microphone...',
      VoicePhase.idle => 'Hold the mic to speak',
      // Two different modes, two different instructions. In wake mode there is
      // no button to release, so "release to send" was actively misleading.
      VoicePhase.listening => _wakeSession
          ? 'Listening — speak your command, then pause'
          : 'Listening — release to send',
      VoicePhase.executing => 'Sending the command...',
      VoicePhase.done => 'Done — hold the mic to speak again',
      VoicePhase.error => 'Hold the mic to try again',
      VoicePhase.unavailable => 'Voice control unavailable',
    };
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: V3Spacing.xs),
        child: Text(
          text.toUpperCase(),
          style:  TextStyle(
            color: V3Colors.textSecondary,
            fontSize: V3Typography.overlineSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
          ),
        ),
      );

  Widget _commandRow(String command, String hint) => Padding(
        padding: const EdgeInsets.symmetric(vertical: V3Spacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Icon(Icons.format_quote,
                size: 16, color: V3Colors.textSecondary),
            const SizedBox(width: V3Spacing.sm),
            Expanded(
              child: Text(
                command,
                style:  TextStyle(
                  color: V3Colors.textPrimary,
                  fontSize: V3Typography.bodySize,
                  height: 1.6, // Ethiopic needs the taller line height
                ),
              ),
            ),
            const SizedBox(width: V3Spacing.sm),
            Text(
              hint,
              style:  TextStyle(
                color: V3Colors.textSecondary,
                fontSize: V3Typography.captionSize,
              ),
            ),
          ],
        ),
      );

  Widget _panel({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
    String? extra,
    bool bodyIsPrimary = false,
  }) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(V3Spacing.md),
        decoration: BoxDecoration(
          color: V3Colors.surface,
          borderRadius: BorderRadius.circular(V3Radius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(width: V3Spacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style:  TextStyle(
                      color: V3Colors.textPrimary,
                      fontSize: V3Typography.labelSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: V3Spacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                body,
                style: TextStyle(
                  color: bodyIsPrimary
                      ? V3Colors.textPrimary
                      : V3Colors.textSecondary,
                  fontSize: V3Typography.bodySize,
                  height: 1.5,
                ),
              ),
            ),
            if (extra != null) ...[
              const SizedBox(height: V3Spacing.xs),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(
                  extra,
                  style:  TextStyle(
                    color: V3Colors.textSecondary,
                    fontSize: V3Typography.captionSize,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
}
