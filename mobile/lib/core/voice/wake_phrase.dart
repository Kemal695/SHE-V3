// =============================================================================
// SHE V3 — Wake phrase recognition (shared)
// =============================================================================
// Mirrors RobiWakeService.isWakePhrase() in Kotlin. Kept in sync deliberately:
// the service matches the phrase against AUDIO (sherpa-onnx keywords), while the
// app needs to spot it inside a TRANSCRIPT — for barge-in, i.e. the user saying
// "Hey Robi" again while a command session is listening, to abort it.
//
// The rule is the same and stays narrow: an explicit "hey" AND a token starting
// with "rob", because "Robi" is a coined word that recognisers spell however the
// nearest English word falls — roby, robby, robie.
// =============================================================================

/// True when [text] contains the wake phrase ("hey robi" / "hey roby" / …).
bool isWakePhrase(String text) {
  final lower = text.toLowerCase();
  if (!lower.contains('hey')) return false;
  return lower
      .split(RegExp(r'[\s,.!?]+'))
      .any((token) => token.startsWith('rob'));
}
