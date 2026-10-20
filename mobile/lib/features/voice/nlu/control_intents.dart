// =============================================================================
// SHE V3 — Control intents (cancel / stop / correct / reject / undo / yes-no)
// =============================================================================
// Spec: docs/voce command.md §6.1 and §6.3.
//
// These are checked BEFORE ordinary device interpretation, whenever a voice
// session, clarification or confirmation is open. A cancellation utterance must
// never be parsed as a device command — "no" must not become "turn off".
//
// The classifier is deliberately a pure function of (text, dialogue state). It
// does not touch devices, the network, or timers, so every rule here is unit
// testable without a phone.
// =============================================================================

import 'amharic_normalizer.dart';

/// What the dialogue is currently waiting for. Changes what "no" means.
enum DialogueExpectation {
  /// Nothing pending — "no" is not a control word on its own.
  none,

  /// A yes/no question was asked ("Do you mean the bedroom light?").
  confirmation,

  /// A clarification was asked ("Which room?").
  clarification,
}

/// The control intents from §6.1, plus yes/no answers from §6.3.
enum ControlIntent {
  /// Not a control utterance — hand the text to the command parser.
  none,

  /// Abandon the current capture/clarification/confirmation. Executes nothing.
  cancel,

  /// Stop a running actuator (gate, irrigation). Only meaningful when something
  /// is actually moving; the caller decides, this only classifies the words.
  stop,

  /// Replace one resolved field ("no, the other room") and re-resolve.
  correctTarget,

  /// Reject the proposed interpretation.
  rejectConfirmation,

  /// Accept the proposed interpretation (still subject to policy checks).
  confirm,

  /// Reverse the last eligible, verified action.
  undo,
}

class ControlMatch {
  final ControlIntent intent;

  /// For [ControlIntent.correctTarget]: the utterance with the negative prefix
  /// removed, e.g. "the other room" / "the living room".
  final String? correctionText;

  /// How sure the classifier is. Control words are short and unambiguous, so
  /// this is 1.0 for an exact single-word answer and 0.9 for a phrase.
  final double confidence;

  const ControlMatch(this.intent, {this.correctionText, this.confidence = 1.0});

  static const none = ControlMatch(ControlIntent.none, confidence: 0);
}

/// Single-word negatives. Matched as whole tokens only — "no" inside "not" or
/// inside an Amharic word must not fire.
const Set<String> _negativeTokens = {
  // English
  'no', 'nope', 'nah', 'negative',
  // Amharic (spec §6.3 candidates; a fluent speaker should review the list)
  'አይ', 'አይደለም', 'አልተሳካም',
};

/// Single-word affirmatives.
const Set<String> _affirmativeTokens = {
  // English
  'yes', 'yeah', 'yep', 'yup', 'correct', 'right', 'ok', 'okay', 'sure',
  'confirm', 'confirmed',
  // Amharic
  'አዎ', 'አዎን', 'እሺ', 'በትክክል',
};

/// Multi-word affirmatives ("that's right", "do it").
const List<List<String>> _affirmativePhrases = [
  ['thats', 'right'],
  ['that', 'is', 'right'],
  ['do', 'it'],
  ['go', 'ahead'],
];

/// Multi-word negatives that are NOT corrections ("not that one").
const List<List<String>> _rejectPhrases = [
  ['not', 'that'],
  ['not', 'that', 'one'],
  ['not', 'this', 'one'],
];

/// Cancellation words. Checked before anything else.
const Set<String> _cancelTokens = {
  'cancel', 'abort', 'quit', 'stop', 'nevermind',
  // Amharic (review required — "ተወው" is context dependent, per the spec)
  'ተወው', 'ተወውት', 'ሰርዝ', 'አቋርጥ', 'ቀረው',
};

const List<List<String>> _cancelPhrases = [
  ['never', 'mind'],
  ['forget', 'it'],
  ['forget', 'about', 'it'],
  ['stop', 'listening'],
  ['cancel', 'that'],
];

/// Undo words.
const Set<String> _undoTokens = {'undo', 'revert'};
const List<List<String>> _undoPhrases = [
  ['undo', 'that'],
  ['put', 'it', 'back'],
  ['turn', 'it', 'back'],
];

/// Words that introduce a replacement target: "I meant the bedroom",
/// "change it to the living room".
const List<List<String>> _correctionPhrases = [
  ['i', 'meant'],
  ['i', 'mean'],
  ['change', 'it', 'to'],
  ['make', 'it'],
  ['not', 'the'],
];

/// "the other room" / "the other one" — a correction with no explicit name.
const List<List<String>> _otherPhrases = [
  ['the', 'other'],
  ['other', 'one'],
  ['the', 'other', 'room'],
];

class ControlIntentClassifier {
  const ControlIntentClassifier();

  /// Classify [transcript] in the context of [expecting].
  ///
  /// Order matters and follows §6.1 rule 7:
  ///   cancel/undo  >  correction  >  stop  >  yes/no  >  none
  ControlMatch classify(
    String transcript, {
    DialogueExpectation expecting = DialogueExpectation.none,
  }) {
    final tokens = amharicNormalizer.tokens(transcript);
    if (tokens.isEmpty) return ControlMatch.none;

    // ---- 1. Cancel -------------------------------------------------------
    // Explicit cancellation wins even while a confirmation is open: "cancel"
    // during a yes/no question is a rejection AND an end to the transaction,
    // which is stronger than a bare "no".
    if (_matchesSingle(tokens, _cancelTokens) ||
        _containsPhrase(tokens, _cancelPhrases)) {
      // "stop" alone is ambiguous: it can mean "stop listening" or "stop the
      // gate". With nothing pending there is nothing to cancel, so treat it as
      // a stop request and let the caller decide whether an actuator is running.
      final onlyStop = tokens.length == 1 && tokens.first == 'stop';
      if (onlyStop && expecting == DialogueExpectation.none) {
        return const ControlMatch(ControlIntent.stop);
      }
      return const ControlMatch(ControlIntent.cancel);
    }

    // ---- 2. Undo ---------------------------------------------------------
    if (_matchesSingle(tokens, _undoTokens) ||
        _containsPhrase(tokens, _undoPhrases)) {
      return const ControlMatch(ControlIntent.undo);
    }

    // ---- 3. Correction ---------------------------------------------------
    // A correction carries a NEW target. It must be recognised before the
    // negative check, otherwise "no, the other room" would only reject and the
    // user's actual intent would be lost.
    final correction = _correctionText(tokens);
    if (correction != null) {
      return ControlMatch(
        ControlIntent.correctTarget,
        correctionText: correction,
        confidence: 0.9,
      );
    }

    // ---- 4. Yes / no -----------------------------------------------------
    final hasNegative = tokens.any(_negativeTokens.contains);
    final hasAffirmative = tokens.any(_affirmativeTokens.contains) ||
        _containsPhrase(tokens, _affirmativePhrases);

    // Both polarities in one utterance ("no, yes") is not a usable answer.
    if (hasNegative && hasAffirmative) return ControlMatch.none;

    if (expecting == DialogueExpectation.confirmation) {
      if (hasAffirmative) return const ControlMatch(ControlIntent.confirm);
      if (hasNegative) {
        return const ControlMatch(ControlIntent.rejectConfirmation);
      }
      if (_containsPhrase(tokens, _rejectPhrases)) {
        return const ControlMatch(ControlIntent.rejectConfirmation);
      }
    }

    // Outside a confirmation prompt, "no" alone is not a control command —
    // but it IS a legitimate way to abandon a clarification.
    if (expecting == DialogueExpectation.clarification && hasNegative) {
      return const ControlMatch(ControlIntent.cancel);
    }

    return ControlMatch.none;
  }

  /// Extract the replacement target from a correction, or null.
  ///
  /// Handles:
  ///   "no, the other room"      -> "the other room"
  ///   "no, the living room"     -> "the living room"
  ///   "i meant the bedroom"     -> "the bedroom"
  ///   "change it to the garage" -> "the garage"
  ///
  /// A bare "no" is NOT a correction — it has no replacement target, and
  /// treating it as one would silently re-resolve to a different device.
  String? _correctionText(List<String> tokens) {
    // Explicit correction phrases: keep everything after the phrase.
    for (final phrase in _correctionPhrases) {
      final idx = _indexOfPhrase(tokens, phrase);
      if (idx >= 0) {
        final rest = tokens.sublist(idx + phrase.length);
        if (rest.isNotEmpty) return rest.join(' ');
      }
    }

    // "no, <something>" — a negative followed by a real target.
    if (tokens.length >= 3 && _negativeTokens.contains(tokens.first)) {
      return tokens.sublist(1).join(' ');
    }

    // "the other room" on its own is still a correction.
    if (_containsPhrase(tokens, _otherPhrases)) return tokens.join(' ');

    return null;
  }

  bool _matchesSingle(List<String> tokens, Set<String> words) {
    // A single-word answer only. "cancel the kitchen" is not a cancel word.
    if (tokens.length != 1) return false;
    return words.contains(tokens.first);
  }

  bool _containsPhrase(List<String> tokens, List<List<String>> phrases) =>
      phrases.any((p) => _indexOfPhrase(tokens, p) >= 0);

  int _indexOfPhrase(List<String> tokens, List<String> phrase) {
    if (phrase.isEmpty || phrase.length > tokens.length) return -1;
    for (var i = 0; i + phrase.length <= tokens.length; i++) {
      var all = true;
      for (var j = 0; j < phrase.length; j++) {
        if (tokens[i + j] != phrase[j]) {
          all = false;
          break;
        }
      }
      if (all) return i;
    }
    return -1;
  }
}

const controlIntentClassifier = ControlIntentClassifier();
