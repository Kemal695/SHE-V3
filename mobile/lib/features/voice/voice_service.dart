// =============================================================================
// SHE V3 — Voice control service (phone-side)
// =============================================================================
// Owns the *wiring* between the recognizer, the shared command brain and the
// SHE REST API the rest of the app uses. Nothing here is voice-specific on the
// backend: a spoken "turn off light 1" ends up as the identical PUT that a tap
// sends.
//
// Phase 3 (Plan §D.7–§D.9): the speech recognizer is no longer hard-coded.
// This service depends only on the [SpeechRecognitionProvider] abstraction; the
// concrete Android provider (speech_to_text) is injected, and an offline ASR can
// be swapped in later behind a feature flag. The provider preserves the exact
// pre-Phase-3 recognition behaviour (am-ET probing, listen timing, fallback).
//
// Why phone-side rather than the firmware Picovoice path (Phase 4C, R16-only):
//   - works on every SKU, including the R24 bench board (no mic on the board)
//   - no Picovoice access key, no trained wake-word model, no SDK to vendor
//   - reuses the existing device/scene endpoints, so nothing new to secure
// The tradeoff, stated plainly: it needs the phone and an internet-backed
// recognizer rather than being truly offline on the device.
// =============================================================================

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_intent.dart';
import '../robi/application/handle_utterance.dart';
import '../robi/application/command_executor.dart';
import '../robi/data/speech_recognition_provider.dart';
import '../robi/data/android_speech_provider.dart';
import '../robi/data/native_speech_provider.dart';

/// Where the voice interaction currently is. Drives the UI honestly: the mic
/// only pulses while we are genuinely capturing audio.
// VoicePhase / VoiceState now live in the presentation layer
// (lib/features/robi/presentation/voice_state.dart) and are re-exported here
// for backward compatibility with screens that import them from this file.
export '../robi/presentation/voice_state.dart' show VoicePhase, VoiceState;
// VoiceAvailability moved to the recognition contract (Phase 3); re-exported so
// any screen that referenced it from here keeps working.
export '../robi/data/speech_recognition_provider.dart' show VoiceAvailability;

final voiceServiceProvider = Provider<VoiceService>((ref) => VoiceService(ref));

/// Whether the phone's recognizer can be used at all. Resolved once per screen
/// open so the UI can show a truthful message instead of a dead mic.
///
/// autoDispose: the answer depends on the app's language (Amharic requests
/// `am-ET` even when it is not listed), so switching language in Settings must
/// re-probe instead of reusing the previous result for the whole app lifetime.
final voiceAvailabilityProvider =
    FutureProvider.autoDispose<VoiceAvailability>((ref) async {
  final service = ref.read(voiceServiceProvider);
  return service.probe();
});

class VoiceService {
  final Ref ref;
  final CommandExecutor _commandExecutor;
  final HandleUtterance _brain;
  final SpeechRecognitionProvider _recognizer;

  VoiceService(
    this.ref, {
    SpeechRecognitionProvider? recognizer,
  })  : _commandExecutor = CommandExecutor(ref),
        _brain = HandleUtterance(ref, CommandExecutor(ref)),
        // Native first: it is the only path that can set EXTRA_BIASING_STRINGS
        // (see native_speech_provider.dart). It falls back to the plugin itself
        // if the platform channel is missing, so voice cannot go dead.
        _recognizer = recognizer ?? NativeSpeechProvider();

  // ---- Capability probe --------------------------------------------------

  /// Decide whether we can listen, and in which language.
  ///
  /// Delegates to the recognition provider (Phase 3). The provider still
  /// requests am-ET speculatively and reports
  /// [VoiceAvailability.amharicUnsupported] honestly — identical behaviour to
  /// before the extraction.
  Future<VoiceAvailability> probe() => _recognizer.probe();

  // ---- Listening ---------------------------------------------------------

  /// [pushToTalk] changes the *stop* conditions to suit a hold-to-record button.
  ///
  /// Default (false) — "listen until the sentence finishes": stop 3 s after the
  /// user goes quiet, and hard-stop at 12 s. Right for a tap-to-start button.
  ///
  /// [pushToTalk] (true) — the RELEASE is the stop. The silence window is pushed
  /// out to 30 s and the cap to 30 s, because a 3 s `pauseFor` cut the recording
  /// off *while the user was still holding the button*.
  ///
  /// [fromWake] — a wake-word opened this session, so the silence window is
  /// longer (measured: 3 s ended the session before the user started the command).
  Future<void> startListening({
    required void Function(
      String transcript,
      bool isFinal,
      List<String> hypotheses,
    ) onResult,
    required void Function() onDone,
    bool pushToTalk = false,
    bool fromWake = false,
  }) =>
      _recognizer.listen(
        onResult: onResult,
        onDone: onDone,
        pushToTalk: pushToTalk,
        fromWake: fromWake,
      );

  Future<void> stopListening() => _recognizer.stop();

  Future<void> cancel() => _recognizer.cancel();

  bool get isListening => _recognizer.isListening;

  /// True when the current recognizer produces Ethiopic script.
  bool get transcriptIsAmharic => _recognizer.isAmharic;

  // ---- Execution ---------------------------------------------------------

  /// Parse [transcript] and perform the resulting action.
  ///
  /// Now delegates to [CommandExecutor] — the single place voice commands reach
  /// the existing SHE device services (Plan §3). Retained as a thin wrapper so
  /// any external caller keeps working.
  Future<({VoiceIntent intent, String message})> handle(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
  }) =>
      _commandExecutor
          .executeTranscript(
            transcript,
            homeId: homeId,
            latinDeviceTokens: latinDeviceTokens,
            amharic: _recognizer.isAmharic,
          )
          .then((r) => (intent: r.intent, message: r.message));

  // ---- Shared brain ------------------------------------------------------
  // Both entry points (the FAB and the voice screen) reach [HandleUtterance]
  // through [handleUtterance]; the native wake word will too. One brain, one
  // pending dialogue — the spec's "shared command brain".

  /// Interpret [transcript], decide whether it is safe to run, and either run it
  /// or ask a question. Delegates to [HandleUtterance] (the shared brain).
  Future<({VoiceIntent intent, String message})> handleUtterance(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
  }) =>
      _brain.handleUtterance(
        transcript,
        homeId: homeId,
        latinDeviceTokens: latinDeviceTokens,
        amharic: _recognizer.isAmharic,
      );

  /// Like [handleUtterance], but first picks the best of the recognizer's
  /// alternative transcripts.
  ///
  /// Android returns several hypotheses per utterance and the top one is not
  /// always the best: "turn on second one socket sock" scores highest while
  /// "turn on socket one socket to sock" is the one that actually names devices.
  /// Parsing them all costs a few milliseconds and turns "Robi doesn't
  /// understand me" into a command that runs.
  Future<({VoiceIntent intent, String message})> handleUtterances(
    List<String> hypotheses, {
    required String homeId,
    required bool latinDeviceTokens,
  }) async {
    if (hypotheses.length <= 1) {
      return handleUtterance(
        hypotheses.isEmpty ? '' : hypotheses.first,
        homeId: homeId,
        latinDeviceTokens: latinDeviceTokens,
      );
    }
    final best = await _brain.bestHypothesis(
      hypotheses,
      homeId: homeId,
      latinDeviceTokens: latinDeviceTokens,
      amharic: _recognizer.isAmharic,
    );
    return handleUtterance(
      best,
      homeId: homeId,
      latinDeviceTokens: latinDeviceTokens,
    );
  }
}
