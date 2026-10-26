// =============================================================================
// SHE V3 — Offline speech provider (Phase 3, Plan §D.9 — GATED STUB)
// =============================================================================
// Offline Amharic command transcription is NOT available yet. The wake-word
// spotter (sherpa-onnx KWS) only detects "Hey Robi"; it does not transcribe.
// This provider exists so the architecture has a slot for an offline engine, but
// until one passes the Plan §5 gate (accuracy, latency, memory, licensing) it
// reports unsupported and is never selected as the default.
//
// DO NOT wire this as the default. Swap it in only after a measured engine
// exists. See the evaluation checklist at the bottom of this file.
import 'speech_recognition_provider.dart';

/// Master switch for offline ASR. Keep false until an engine clears the gate.
const bool offlineAsrEnabled = false;

class OfflineSpeechProvider implements SpeechRecognitionProvider {
  @override
  Future<bool> init() async => false;

  @override
  Future<List<SpeechLocale>> locales() async => <SpeechLocale>[];

  @override
  Future<VoiceAvailability> probe({bool? wantsAmharic}) async {
    // Honest: there is no offline recognizer yet. The UI shows this reason.
    return const VoiceAvailability.unavailable(
      'Offline voice recognition is not available on this device. '
      'Connect to the internet and try again.',
    );
  }

  @override
  Future<void> listen({
    required void Function(
      String transcript,
      bool isFinal,
      List<String> hypotheses,
    ) onResult,
    required void Function() onDone,
    bool pushToTalk = false,
    bool fromWake = false,
  }) async {
    // Never reached while disabled; throw so a wrong wiring fails loudly
    // rather than silently doing nothing.
    throw UnimplementedError('OfflineSpeechProvider.listen: offline ASR is not '
        'implemented (offlineAsrEnabled=$offlineAsrEnabled).');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  bool get isListening => false;

  @override
  bool get isAmharic => false;
}

// -----------------------------------------------------------------------------
// Evaluation checklist — an offline engine must clear ALL of these before this
// provider is switched on (Plan §5 / §9):
//   1. Accuracy: word-error-rate on a held-out Amharic command set beats the
//      current online recognizer for the supported device/scene vocabulary.
//   2. Latency: end-of-speech -> first result p95 < 1.5 s on the TECNO LE6.
//   3. Memory: model + runtime fit under the app's memory budget with the rest
//      of SHE resident.
//   4. Licensing: the model and runtime are redistributable offline (no API
//      key, no per-request fee).
//   5. Integration: speak("turn on light 1") -> parseVoiceIntent resolves the
//      same intent the online path does, on-device.
// Until then, offlineAsrEnabled stays false and this provider is inert.
// -----------------------------------------------------------------------------
