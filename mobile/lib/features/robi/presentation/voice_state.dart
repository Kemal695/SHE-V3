// =============================================================================
// SHE V3 — Voice UI state (presentation layer)
// =============================================================================
// Extracted from voice_service.dart so the UI state model lives with the
// presentation layer (Plan §8). VoiceService re-exports these for backward
// compatibility with screens that import them from voice_service.
// =============================================================================

import '../domain/voice_command.dart';

/// Where the voice interaction currently is. Drives the UI honestly: the mic
/// only pulses while we are genuinely capturing audio.
enum VoicePhase {
  /// No recognizer yet — the screen is deciding whether it can listen at all.
  initializing,

  idle,
  listening,

  /// Heard something; resolving and calling the API.
  executing,
  done,

  /// Something failed and the screen needs to say so.
  error,

  /// No usable recognizer (or permission refused) — explain, don't pretend.
  unavailable,
}

class VoiceState {
  final VoicePhase phase;
  final String? transcript;
  final VoiceIntent? intent;
  final String? message;
  final bool onDevice;

  const VoiceState({
    this.phase = VoicePhase.initializing,
    this.transcript,
    this.intent,
    this.message,
    this.onDevice = false,
  });

  VoiceState copyWith({
    VoicePhase? phase,
    String? transcript,
    VoiceIntent? intent,
    String? message,
    bool? onDevice,
    bool clearTranscript = false,
    bool clearIntent = false,
    bool clearMessage = false,
  }) =>
      VoiceState(
        phase: phase ?? this.phase,
        transcript: clearTranscript ? null : (transcript ?? this.transcript),
        intent: clearIntent ? null : (intent ?? this.intent),
        message: clearMessage ? null : (message ?? this.message),
        onDevice: onDevice ?? this.onDevice,
      );
}
