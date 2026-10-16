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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../device_detail/node_service.dart';
import 'voice_intent.dart';
import 'voice_service.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

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
  }

  bool get _listening => _phase == VoicePhase.listening;

  /// Push-to-talk: called on pointer-down. Records until the finger lifts.
  Future<void> _startListening() async {
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
    });
    _pulseController.repeat(reverse: true);

    _starting = true;
    try {
      await service.startListening(
        // Push-to-talk: the finger lifting ends the recording, not silence.
        pushToTalk: true,
        onResult: (text, isFinal) {
          if (!mounted) return;
          setState(() => _transcript = text);
          if (isFinal) _finish(text);
        },
        onDone: () {
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
    _pulseController.stop();
    if (!mounted) return;
    setState(() => _phase = VoicePhase.executing);

    final service = ref.read(voiceServiceProvider);
    try {
      final result = await service.handle(
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final availability = ref.watch(voiceAvailabilityProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon:  Icon(Icons.arrow_back, color: V3Colors.textPrimary),
          onPressed: () => context.go('/dashboard'),
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
                        title: 'Listening in English',
                        body: a.reason ??
                            'This phone has no Amharic recognizer, so speak '
                                'English commands.',
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
                        SizedBox(width: V3Spacing.sm),
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
      VoicePhase.listening => 'Listening — release to send',
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
