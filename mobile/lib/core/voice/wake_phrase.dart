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

/// Words a recognizer returns for the wake phrase, or for our own "Yes?" cue.
///
/// "Robi" is not a word, so the recognizer writes whatever is nearest: measured
/// on the TECNO LE6 it returned `"he's"` for the tail of "Hey Robi".
const Set<String> _echoTokens = {
  'hey', 'hay', 'he', 'hes', "he's", "it's", 'its', 'his', 'is', 'it',
  'hi', 'hello', 'robi', 'roby', 'robby', 'rob', 'robie',
  'yes', 'yeah', 'yep', 'ya', 'ok', 'okay', 'alright',
  'hmm', 'um', 'uh', 'ah', 'oh', 'the', 'a', 'that',
};

/// True when [text] is ONLY the tail of the wake phrase, not a command.
///
/// [isWakePhrase] is deliberately narrow — it needs both "hey" and a "rob"
/// token — because it decides whether to abort a command that is already
/// running. A wake session needs the opposite bias: the keyword detector fires
/// on the phrase's last syllable, so the recognizer's first final is normally
/// the tail ("he's", "hey", "yes"). Treating that as the command ends the
/// session before the user has spoken, which is why "turn on socket 1 socket 2
/// and light 1" and "is socket 2 on" appeared to do nothing.
///
/// The wake phrase is stripped FIRST, so a command spoken in the same breath
/// ("hey robi turn on socket 1") is not mistaken for an echo — the parser
/// handles that transcript correctly and it must be executed.
bool isWakeEcho(String text) {
  final toks = _tokensOf(text);
  if (toks.isEmpty) return true;

  final rest = <String>[];
  for (var i = 0; i < toks.length; i++) {
    if (_heyTokens.contains(toks[i]) &&
        i + 1 < toks.length &&
        toks[i + 1].startsWith('rob')) {
      i++; // skip the name as well
      continue;
    }
    rest.add(toks[i]);
  }

  if (rest.isEmpty) return true;
  // Up to three words, ALL of them wake-word debris. "is it okay" and "it's
  // okay" are how the LE6 transcribes the tail of "Hey Robi"; "socket 2 on" is
  // also three words but contains "socket", so it is never mistaken for one.
  if (rest.length > 3) return false;
  return rest.every(_echoTokens.contains);
}

List<String> _tokensOf(String text) => text
    .toLowerCase()
    .split(RegExp(r"[^a-z0-9']+"))
    .where((t) => t.isNotEmpty)
    .toList();

/// The "hey" half of the wake phrase, as recognizers spell it.
const Set<String> _heyTokens = {'hey', 'hay', 'he'};
