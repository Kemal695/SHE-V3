// =============================================================================
// SHE V3 — Command NLU (structured interpretation result)
// =============================================================================
// Spec: docs/voce command.md §5.4 and §12 (`CommandNluService`).
//
// Wraps the existing, tested parser (`voice_intent.dart`) and adds the things
// the parser never returned:
//   * the language of the utterance (am / en / mixed)
//   * the resolved device TYPE (light / socket), which the parser only knew as a
//     group noun
//   * the runner-up candidates, so ambiguity can be detected instead of the
//     highest score silently winning
//   * the normalized text alongside the original transcript
//
// It does NOT execute anything and does NOT decide whether execution is safe —
// that is `CommandSafetyPolicy`.
// =============================================================================

import 'amharic_normalizer.dart';
import '../voice_intent.dart';

class NluResult {
  /// What the recognizer produced. Kept verbatim for diagnostics.
  final String transcript;

  /// Normalized copy used for matching.
  final String normalized;

  /// 'am' | 'en' | 'mixed' | 'unknown'
  final String language;

  final VoiceAction action;

  final VoiceDevice? device;
  final String? group;
  final String? sceneId;

  /// 'light' | 'socket' | null — resolved from the group noun or the device name.
  final String? deviceType;

  final double confidence;

  /// Other devices that scored close to the winner. Non-empty means "do not
  /// guess": the user must choose.
  final List<DeviceMatch> candidates;

  const NluResult({
    required this.transcript,
    required this.normalized,
    required this.language,
    required this.action,
    this.device,
    this.group,
    this.sceneId,
    this.deviceType,
    this.confidence = 0,
    this.candidates = const [],
  });

  bool get isUnknown => action == VoiceAction.unknown;
  bool get isAmbiguous => candidates.length > 1;

  /// The label to show/say when asking which device was meant.
  String get candidateLabels =>
      candidates.map((c) => c.device.label).join(', ');
}

class CommandNlu {
  const CommandNlu();

  /// Interpret [transcript] against the current home's devices and scenes.
  ///
  /// [latinDeviceTokens] must stay false in Amharic mode — see the header of
  /// `voice_intent.dart`. Getting this wrong makes any English-sounding
  /// utterance match a Latin device name.
  NluResult interpret(
    String transcript, {
    required List<VoiceDevice> devices,
    List<VoiceScene> scenes = const [],
    bool latinDeviceTokens = true,
    bool amharic = true,
    double ambiguityWindow = 0.05,
  }) {
    final normalized = amharicNormalizer.normalize(transcript);
    final language = amharicNormalizer.detectLanguage(transcript);

    final intent = parseVoiceIntent(
      transcript,
      devices: devices,
      scenes: scenes,
      latinDeviceTokens: latinDeviceTokens,
      amharic: amharic,
    );

    // Only a single-device command can be ambiguous. A group action ("all the
    // lights") and a scene are unambiguous by construction.
    var candidates = const <DeviceMatch>[];
    if (intent.device != null) {
      final scored = scoreDevices(transcript, devices);
      if (scored.isNotEmpty) {
        final top = scored.first.score;
        candidates = scored
            .where((m) => top - m.score <= ambiguityWindow && m.score >= 0.6)
            .toList();
        // A single candidate is not an ambiguity — collapse it.
        if (candidates.length < 2) candidates = const [];
      }
    }

    return NluResult(
      transcript: transcript,
      normalized: normalized,
      language: language,
      action: intent.action,
      device: intent.device,
      group: intent.group,
      sceneId: intent.sceneId,
      deviceType: _deviceType(intent, devices),
      confidence: intent.confidence,
      candidates: candidates,
    );
  }

  /// 'light' / 'socket', from the group noun or the device name prefix.
  ///
  /// The firmware names its channels "Light 1..16" and "Socket 1..8", and the
  /// relay masks are built from the same split, so the prefix is the reliable
  /// signal for a single-device command.
  String? _deviceType(VoiceIntent intent, List<VoiceDevice> devices) {
    if (intent.group != null) {
      return switch (intent.group) {
        'lights' => 'light',
        'sockets' => 'socket',
        _ => null,
      };
    }
    final device = intent.device;
    if (device == null) return null;
    final name = device.deviceName.toLowerCase();
    if (name.startsWith('light')) return 'light';
    if (name.startsWith('socket')) return 'socket';
    return null;
  }
}

const commandNlu = CommandNlu();
