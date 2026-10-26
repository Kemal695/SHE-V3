// =============================================================================
// SHE V3 — Speech recognition abstraction (Phase 3, Plan §D.7)
// =============================================================================
// A recognition provider turns microphone audio into a transcript. The default
// implementation is [AndroidSpeechProvider] (speech_to_text over the device /
// Google cloud recognizer); an offline Amharic ASR would be a second
// implementation selected by feature flag (see offline_speech_provider.dart).
//
// The contract deliberately mirrors the PRE-Phase-3 VoiceService behaviour so
// the extraction is behaviour-preserving: it probes capability (requesting am-ET
// even when the phone does not list it, and reporting amharicUnsupported
// honestly), and it exposes the same listen timing (12/3, 15/6, 30/30 s for
// tap / wake / push-to-talk).
//
// This file is intentionally free of any speech_to_text types so that consumers
// (and tests) depend only on the abstraction.

/// A locale the recognizer can work in, decoupled from speech_to_text's
/// [LocaleName] so the abstraction owns no concrete-engine types.
class SpeechLocale {
  final String localeId;
  const SpeechLocale(this.localeId);
}

/// Whether the phone's recognizer can be used, and in which language.
///
/// Moved here from VoiceService so the recognition contract is self-contained;
/// VoiceService re-exports it for backward compatibility with screens.
class VoiceAvailability {
  final bool available;
  final bool onDevice;
  final String? reason;

  /// Locale we will ask for, and whether it is Amharic. Both are decided at
  /// probe time because locale support is a device capability, not a constant.
  final String localeId;
  final bool amharic;

  /// True when the app wants Ethiopic but the device can only do Latin. The UI
  /// surfaces this because it changes what the user should say.
  final bool amharicUnsupported;

  const VoiceAvailability({
    required this.available,
    required this.onDevice,
    required this.localeId,
    required this.amharic,
    this.amharicUnsupported = false,
    this.reason,
  });

  const VoiceAvailability.unavailable(this.reason)
      : available = false,
        onDevice = false,
        localeId = 'en-US',
        amharic = false,
        amharicUnsupported = false;
}

/// The recognition contract. [VoiceService] depends only on this abstraction;
/// the concrete engine (Android speech_to_text today, offline ASR later) is
/// supplied at construction time.
abstract class SpeechRecognitionProvider {
  /// Initialize the underlying engine. Idempotent; safe to call before [probe].
  Future<bool> init();

  /// The locales the engine can recognize.
  Future<List<SpeechLocale>> locales();

  /// Probe capability and choose a locale.
  ///
  /// [wantsAmharic] overrides the stored app locale when provided; otherwise the
  /// app's saved locale (Amharic-first) decides whether we ask for am-ET.
  Future<VoiceAvailability> probe({bool? wantsAmharic});

  /// Begin listening. [onResult] fires for partial and final results; [onDone]
  /// when the session ends. Timing follows the current behaviour: tap (default)
  /// = 12 s cap / 3 s silence, wake = 15 s / 6 s, push-to-talk = 30 s / 30 s.
  Future<void> listen({
    required void Function(
      String transcript,
      bool isFinal,
      List<String> hypotheses,
    ) onResult,
    required void Function() onDone,
    bool pushToTalk = false,
    bool fromWake = false,
  });

  Future<void> stop();
  Future<void> cancel();

  bool get isListening;

  /// True when the current session transcribes Ethiopic script.
  bool get isAmharic;
}
