// =============================================================================
// SHE V3 — Press-and-hold voice button (embeddable)
// =============================================================================
// A compact push-to-talk mic that can be dropped onto any screen. It is wired
// into the device/node page so voice sits next to the devices it controls,
// instead of only living behind the separate /voice route.
//
// Hold to record, release to send. It owns no UI beyond the button itself — the
// outcome is reported through a SnackBar so the host screen does not have to
// grow a voice panel. VoiceScreen still exists for the richer view (live
// transcript, parsed intent, example commands).
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/v3_design_tokens.dart';
import '../device_detail/node_service.dart';
import 'voice_service.dart';

class VoiceHoldButton extends ConsumerStatefulWidget {
  const VoiceHoldButton({super.key, this.heroTag});

  /// Passed through to the FloatingActionButton wrapper by the host screen.
  final Object? heroTag;

  @override
  ConsumerState<VoiceHoldButton> createState() => _VoiceHoldButtonState();
}

class _VoiceHoldButtonState extends ConsumerState<VoiceHoldButton> {
  /// Recognizer is live and capturing.
  bool _listening = false;

  /// Finger is down right now.
  ///
  /// Set **synchronously** in the pointer-down handler, and re-checked after
  /// every `await` in `_begin()`. Without this, a press-and-release that lands
  /// while the availability probe is still resolving sets no flag at all: the
  /// release handler sees `!_listening` and returns, then the probe finishes and
  /// starts recording with nothing left to stop it. The button would appear dead
  /// on a quick press and then keep the mic open.
  bool _pressed = false;

  /// Resolved once, lazily: `handle()` needs a home id, and this widget can be
  /// dropped on screens that never loaded the home list themselves.
  String? _homeId;

  /// Used when the home list cannot be read. Matches the id the backend seeds.
  static const String _defaultHomeId = '00000000-0000-0000-0000-000000000001';

  @override
  void dispose() {
    // Never leave the microphone open behind a popped route — Android keeps the
    // privacy indicator on and it drains the battery.
    ref.read(voiceServiceProvider).cancel();
    super.dispose();
  }

  /// Always returns a usable id, so callers do not have to null-check.
  ///
  /// Note the local `cached`: `_homeId` is a mutable instance field, and Dart
  /// only promotes *locals* after a null check — `if (_homeId != null) return
  /// _homeId;` would still have static type `String?` and fail to compile.
  Future<String> _resolveHomeId() async {
    final cached = _homeId;
    if (cached != null) return cached;

    var resolved = _defaultHomeId;
    try {
      final homes = await ref.read(nodeServiceProvider).listHomes();
      if (homes.isNotEmpty) {
        // Defensive: the key has appeared as both `id` and `home_id`.
        final id = (homes.first['id'] ?? homes.first['home_id'])?.toString();
        if (id != null && id.isNotEmpty) resolved = id;
      }
    } catch (_) {
      // Fall through to the default; the command may still work.
    }
    _homeId = resolved;
    return resolved;
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: Duration(seconds: error ? 4 : 2),
          backgroundColor: error ? V3Colors.error : null,
        ),
      );
  }

  void _onPointerDown() {
    _pressed = true;
    _begin();
  }

  void _onPointerUp() {
    if (!_pressed) return;
    _pressed = false;
    _end();
  }

  Future<void> _begin() async {
    if (_listening) return;

    // Glow NOW. The finger is already down, and waiting for the availability
    // probe below left the button looking dead for the first few hundred ms —
    // which reads as "the mic didn't register my press".
    setState(() => _listening = true);

    // Probe: on a phone with no recognizer (or mic permission refused) we must
    // say so rather than leaving a button that will never hear anything.
    final availability = await ref.read(voiceAvailabilityProvider.future);
    if (!mounted) return;

    // The finger may already be gone — a quick tap, or a slow probe. Bail before
    // opening the mic, otherwise we would record with nothing left to stop it.
    if (!_pressed) {
      setState(() => _listening = false);
      return;
    }

    if (!availability.available) {
      setState(() => _listening = false);
      _say(availability.reason ?? 'Voice control is unavailable on this phone.',
          error: true);
      return;
    }

    await ref.read(voiceServiceProvider).startListening(
      // Release, not silence, ends this recording.
      pushToTalk: true,
      onResult: (text, isFinal) {
        if (isFinal) _run(text);
      },
      onDone: () {
        if (!mounted) return;
        if (_listening) setState(() => _listening = false);
      },
    );
  }

  Future<void> _end() async {
    // Drop the glow on the SAME frame as the release.
    //
    // It used to wait for the recogniser's `onDone`, which lands a few hundred
    // ms later — so the button kept pulsing after the finger was already gone,
    // and a second press during that window was swallowed.
    if (_listening && mounted) {
      setState(() => _listening = false);
    }
    // Stop unconditionally rather than only `if (_listening)`: _begin() may
    // still be awaiting its availability probe, and startListening() would then
    // open the mic with nothing left to close it.
    await ref.read(voiceServiceProvider).stopListening();
  }

  Future<void> _run(String transcript) async {
    if (!mounted) return;
    setState(() => _listening = false);

    final homeId = await _resolveHomeId();
    final service = ref.read(voiceServiceProvider);
    try {
      final result = await service.handle(
        transcript,
        homeId: homeId,
        // Only trust Latin device tokens when the recognizer really is Latin.
        latinDeviceTokens: !service.transcriptIsAmharic,
      );
      _say(
        result.intent.isUnknown
            ? 'Heard "$transcript" — not a command I know.'
            : result.message,
        error: result.intent.isUnknown,
      );
    } catch (e) {
      _say('Command failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final availability = ref.watch(voiceAvailabilityProvider);
    final ready = availability.maybeWhen(
      data: (a) => a.available,
      orElse: () => false,
    );

    return Listener(
      // Raw pointer events, not GestureDetector taps: the host page is a
      // scrollable, and a tap gesture is claimed by the scroll arena the moment
      // the finger drifts — which would cancel recording mid-sentence.
      onPointerDown: (_) => _onPointerDown(),
      onPointerUp: (_) => _onPointerUp(),
      onPointerCancel: (_) => _onPointerUp(),
      // A bare Listener + Container exposes no semantics at all, so the button
      // was invisible to TalkBack *and* to `uiautomator dump` (which made it
      // impossible to drive from adb). One label fixes both.
      child: Semantics(
        button: true,
        enabled: ready,
        label: 'Voice control — hold to speak',
        child: SizedBox(
          width: 64,
          height: 64,
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !ready
                ? V3Colors.surface
                : (_listening ? V3Colors.primary : V3Colors.surface),
            border: Border.all(
              color: _listening ? V3Colors.primary : V3Colors.textSecondary,
              width: 1.5,
            ),
            boxShadow: _listening
                ? [
                    BoxShadow(
                      color: V3Colors.primary.withValues(alpha: 0.45),
                      blurRadius: 22,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
            child: Icon(
              _listening ? Icons.mic : Icons.mic_none,
              size: 28,
              color: !ready
                  ? V3Colors.textSecondary
                  : (_listening ? Colors.white : V3Colors.primary),
            ),
          ),
        ),
      ),
    );
  }
}
