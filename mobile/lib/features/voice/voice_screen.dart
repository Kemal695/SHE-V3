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
import '../../core/voice/voice_log.dart';
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

  /// Hard stop for a wake session.
  ///
  /// `listenFor` should end the session on its own, but when the microphone is
  /// taken away mid-session (another client, or the wake detector re-arming)
  /// the recognizer never calls back and the screen sits on "Listening…"
  /// forever. This guarantees the UI returns to a usable state.
  Timer? _sessionWatchdog;

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
    // Hand the mic back so the wake word works again after this screen closes.
    unawaited(robiWake.resume());
    _pulseController.dispose();
    // Leaving the screen must release the mic — a recognizer left running keeps
    // the Android mic indicator on and burns battery.
    ref.read(voiceServiceProvider).cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
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
      // Keep the placeholder home; the probe below is independent of it.
    }

    final availability = await ref.read(voiceAvailabilityProvider.future);
    if (!mounted) return;
    setState(() {
      _phase = availability.available ? VoicePhase.idle : VoicePhase.unavailable;
      _message = availability.reason;
    });

    // Opened by the wake word: start listening immediately, in sentence mode
    // (not push-to-talk — there is no finger to hold).
    if (widget.autoStart && availability.available) {
      await _startListening(pushToTalk: false);
    }
  }

  bool get _listening => _phase == VoicePhase.listening;

  /// Records until the finger lifts (push-to-talk), or until the sentence
  /// finishes when [pushToTalk] is false (wake-word activation).
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
    try {
      // Take the microphone from the wake detector BEFORE opening the
      // recognizer. Awaiting matters: the detector releases AudioRecord
      // asynchronously, and starting the recognizer first lost the mic.
      await robiWake.pause();
      await service.startListening(
        // Push-to-talk: the finger lifting ends the recording, not silence.
        // Wake-word mode passes false so the sentence decides.
        pushToTalk: pushToTalk,
        // The wake word opened this screen: give the user time to speak.
        fromWake: !pushToTalk,
        onResult: (text, isFinal) {
          if (!mounted) return;
          setState(() => _transcript = text);
          if (isFinal) _finish(text);
        },
        onDone: () {
          // Distinguishes "the session ended with no transcript" from "the
          // session never ended" — the two look identical in the UI.
          _stage('capture: ended (final=${_transcript ?? '<none>'})');
          if (!mounted) return;
          // Nothing finalized (silence, or released before speaking): do not
          // leave the button pulsing forever.
          if (_phase == VoicePhase.listening) {
            setState(() => _phase = VoicePhase.idle);
            _pulseController.stop();
          }
        },
      );
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
  Future<void> _stopListening() async {
    if (_starting) {
      // Recognizer not live yet — remember it and let _startListening finish.
      _releasePending = true;
      return;
    }
    if (!_listening) return;

    _pulseController.stop();
    await ref.read(voiceServiceProvider).stopListening();
  }

  Future<void> _finish(String transcript) async {
    _sessionWatchdog?.cancel();
    _pulseController.stop();

    // Barge-in: the user said "Hey Robi" again because they want to abort and
    // start over (they missed their command, or said the wrong thing). During a
    // session the detector is paused — the session owns the mic — so the phrase
    // arrives inside the transcript and is caught here.
    if (isWakePhrase(transcript)) {
      VoiceLog.log('barge-in: wake phrase during a session — restarting');
      ref.read(voiceServiceProvider).cancel();
      if (mounted) {
        setState(() {
          _phase = VoicePhase.idle;
          _message = 'Restarted — say your command';
          _transcript = null;
          _intent = null;
        });
      }
      await _startListening(pushToTalk: false);
      return;
    }
    if (!mounted) return;
    setState(() => _phase = VoicePhase.executing);

    final service = ref.read(voiceServiceProvider);
    try {
      final result = await service.handleUtterance(
        transcript,
        homeId: _homeId,
        // Only trust Latin device tokens when the recognizer is actually Latin;
        // see voice_intent.dart's header for why this is a correctness guard.
        latinDeviceTokens: !service.transcriptIsAmharic,
      );
      if (!mounted) return;
      setState(() {
        _intent = result.intent;
        _message = result.message;
        _phase = result.intent.isUnknown ? VoicePhase.error : VoicePhase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = VoicePhase.error;
        _message = 'Command failed: $e';
      });
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

    final device = _intent?.device?.label;

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
