// =============================================================================
// SHE V3 — Device name resolver (extracted from the voice parser)
// =============================================================================
// The language- and verb-agnostic half of voice parsing: given a transcript and
// the home's device list, score each device name and report the best match
// (plus the runner-up for ambiguity). Both `parseVoiceIntent` (the parser) and
// `CommandNlu` (the NLU layer) use this, so device-name logic lives in exactly
// one place — see change plan §D.5.
//
// It depends only on the model types in `voice_command.dart`; it never touches
// verbs, scenes, or the recognizer. The helper functions are public (no leading
// underscore) because the parser, in `voice_command.dart`, reuses them — a
// private symbol could not cross the library boundary.
// =============================================================================

import 'voice_command.dart';

// ---------------------------------------------------------------------------
// Shared string helpers
// ---------------------------------------------------------------------------

/// Normalise for comparison: lowercase, collapse whitespace, strip punctuation
/// that recognizers like to append ("Light 1." / "መብራት።").
String norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp("[.,!?\u1362\u1363\u1364\u1365:;\"'\u2019\u201C\u201D()\\[\\]]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Split into tokens on whitespace. Amharic uses U+1361 (፡) as a word space, so
/// treat that as whitespace too.
List<String> tokens(String s) =>
    norm(s).split(RegExp(r'[\s\u1361]+')).where((t) => t.isNotEmpty).toList();

/// True if [haystack] contains any of [needles].
bool containsAny(String haystack, List<String> needles) {
  for (final n in needles) {
    if (haystack.contains(n)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Spoken-number normalisation
// ---------------------------------------------------------------------------

/// Spoken cardinal numbers a recognizer emits as words instead of digits.
///
/// Device names are stored with digits ("Socket 1", "Light 12"), but a user
/// saying "turn on socket one" gets the *word* back. Mapping the word to its
/// digit lets the token-run matcher pair "socket one" with "Socket 1" — without
/// this every numbered command silently degraded to an "all sockets/lights"
/// group action (see `parseVoiceIntent`'s group fallback in `voice_command`).
const Map<String, String> _spokenNumbers = {
  'zero': '0',
  'one': '1',
  'two': '2',
  'three': '3',
  'four': '4',
  'five': '5',
  'six': '6',
  'seven': '7',
  'eight': '8',
  'nine': '9',
  'ten': '10',
  'eleven': '11',
  'twelve': '12',
  'thirteen': '13',
  'fourteen': '14',
  'fifteen': '15',
  'sixteen': '16',
  'seventeen': '17',
  'eighteen': '18',
  'nineteen': '19',
  'twenty': '20',
};

/// Replace spoken cardinal-number words with their digits, after normalising.
///
/// Applied on the device-matching path only (not to verbs, scenes or group
/// nouns), so "turn on the lights" stays a group action and a scene named
/// "Movie Night" is untouched. Non-number words pass through unchanged.
String normalizeSpokenNumbers(String s) {
  final normalised = norm(s);
  if (normalised.isEmpty) return '';
  final toks = normalised.split(RegExp(r'\s+'));
  for (var i = 0; i < toks.length; i++) {
    final word = toks[i];
    final mapped = _spokenNumbers[word] ?? _digitHomophones[word];
    if (mapped == null) continue;
    // A homophone is only a number when no number follows it: "set light to 50
    // percent" means the preposition, not "Light 2". A real number word
    // ("one two three") is always mapped.
    if (_spokenNumbers[word] == null && i + 1 < toks.length) {
      if (RegExp(r'^\d+$').hasMatch(toks[i + 1])) continue;
    }
    toks[i] = mapped;
  }
  return toks.join(' ').trim();
}

/// Digits the recognizer spells as ordinary English words.
///
/// "Robi, socket two" comes back as "socket to" on the LE6, and "socket four"
/// as "socket for". Without this, "is socket to on" fell through to the class
/// noun and answered about EVERY socket, while "turn on socket for" turned them
/// all on — the two symptoms users report as "asking about state is wrong" and
/// "it switches the wrong things".
const Map<String, String> _digitHomophones = {
  'won': '1',
  'to': '2',
  'too': '2',
  'tree': '3',
  'free': '3',
  'for': '4',
  'fore': '4',
  'fife': '5',
  'sick': '6',
  'sicks': '6',
  'sex': '6',
  'ate': '8',
  'niner': '9',
};

/// Speech-to-text misspellings of the two device NOUNS the firmware names use.
///
/// The LE6 recognizer writes "socket" as "soket"/"soke"/"socet" and "light" as
/// "lite"/"lites" often enough that commands silently lost devices:
///
///   "turn on soket 1 soket 2 and light 1" -> only Light 1
///   "is soket 2 on"                       -> "check all sockets"
///
/// Both symptoms the user reports ("can't control 3+ devices", "can't ask about
/// one socket's state"). The fix is token-level only, so ordinary words are
/// never rewritten.
const Map<String, String> _deviceNounMisspellings = {
  'soket': 'socket',
  'soke': 'socket',
  'socet': 'socket',
  'sockt': 'socket',
  'sokets': 'sockets',
  'socets': 'sockets',
  'lite': 'light',
  'lites': 'lights',
  'licht': 'light',
  'lichts': 'lights',
};

/// Rewrite common device-noun misspellings to the firmware spelling, on the
/// device-matching path only (see [_deviceNounMisspellings]).
String normalizeDeviceNounMisspellings(String s) {
  final toks = tokens(s);
  var changed = false;
  for (var i = 0; i < toks.length; i++) {
    final fixed = _deviceNounMisspellings[toks[i]];
    if (fixed != null) {
      toks[i] = fixed;
      changed = true;
    }
  }
  return changed ? toks.join(' ') : norm(s);
}

// ---------------------------------------------------------------------------
// Amharic device words
// ---------------------------------------------------------------------------

/// Amharic device nouns → the Latin word the firmware names use.
const Map<String, String> _amharicNouns = {
  'ሶኬት': 'socket',
  'ሶኬቶች': 'socket',
  'መዘርጋት': 'socket',
  'መዘርጋቶች': 'socket',
  'መብራት': 'light',
  'መብራቶች': 'light',
  'ብርሃን': 'light',
  'ብርሃኖች': 'light',
  'ላምፕ': 'light',
};

/// Amharic cardinal numbers 1..10.
const Map<String, String> _amharicNumbers = {
  'አንድ': '1',
  'ሁለት': '2',
  'ሶስት': '3',
  'አራት': '4',
  'አምስት': '5',
  'ስድስት': '6',
  'ሰባት': '7',
  'ስምንት': '8',
  'ዘጠኝ': '9',
  'አስር': '10',
};

/// Compound numbers 11..16 ("አስራ" + unit), replaced before tokenising.
const Map<String, String> _amharicCompoundNumbers = {
  'አስራ አንድ': '11',
  'አስራ ሁለት': '12',
  'አስራ ሶስት': '13',
  'አስራ አራት': '14',
  'አስራ አምስት': '15',
  'አስራ ስድስት': '16',
};

/// Rewrite Amharic device words into the Latin form the device names use, so an
/// Amharic speaker can target a single device:
///
///   "ሶኬት አንድ ክፈት"  ->  "socket 1 ክፈት"
///
/// Only the NOUN and NUMBER are translated; the verb stays Amharic and is matched
/// by the parser's verb tables. Applied on the device-matching path only, so it
/// cannot disturb verb, group or scene detection.
String normalizeAmharicDeviceText(String s) {
  // U+1361 (Ethiopic word space) is a word separator, not \s — normalise it to a
  // real space so the compound-number replacement and token split both work.
  var t = norm(s).replaceAll('\u1361', ' ');
  if (t.isEmpty) return '';
  for (final e in _amharicCompoundNumbers.entries) {
    t = t.replaceAll(e.key, e.value);
  }
  return t
      .split(RegExp(r'\s+'))
      .map((tok) => _amharicNouns[tok] ?? _amharicNumbers[tok] ?? tok)
      .join(' ')
      .trim();
}

// ---------------------------------------------------------------------------
// Amharic suffix handling
// ---------------------------------------------------------------------------

/// Amharic suffixes that attach to a noun when it is spoken but are absent from
/// a stored device name.
///
/// A device named "ክፍል" (room) is said as "ክፍልን" when it is the object of the
/// verb, and "ክፍሉ" when it is definite. Exact token matching therefore rejected
/// perfectly natural commands — the most common way an Amharic speaker would
/// phrase "turn on the children's room".
///
/// Deliberately a SHORT, closed list: only the object marker (-ን) and the
/// masculine/feminine definite endings (-ው / -ዋ), plus -ም ("also"). Anything
/// longer risks turning one Amharic word into another, which the spec forbids.
const List<String> _amharicSuffixes = ['ን', 'ው', 'ዋ', 'ም'];

/// Does the spoken [transcriptToken] refer to the stored [nameToken]?
///
/// Exact first, then name + one known Amharic suffix. Never the reverse: a
/// stored name is never allowed to be a truncation of the spoken word, so
/// "ክፍል" cannot match "ክፍልት" or some other unrelated word that merely starts
/// the same way.
bool tokenMatches(String nameToken, String transcriptToken) {
  if (nameToken == transcriptToken) return true;
  if (transcriptToken.length <= nameToken.length) return false;
  if (!transcriptToken.startsWith(nameToken)) return false;
  final suffix = transcriptToken.substring(nameToken.length);
  return _amharicSuffixes.contains(suffix);
}

/// Match [name] against the transcript's tokens at word boundaries.
///
/// Returns true if every token of [name] appears contiguously in [tTokens].
/// Comparing tokens rather than substrings is what keeps "Light 1" from
/// matching inside "Light 12".
bool hasTokenRun(List<String> tTokens, List<String> nameTokens) {
  if (nameTokens.isEmpty || nameTokens.length > tTokens.length) return false;
  for (var i = 0; i + nameTokens.length <= tTokens.length; i++) {
    var all = true;
    for (var j = 0; j < nameTokens.length; j++) {
      if (!tokenMatches(nameTokens[j], tTokens[i + j])) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

/// Score [device] against [transcript].
///
/// Returns a score, higher is better, 0 for no match. Three tiers, because the
/// failure modes differ:
///   - exact:  the user named the device and nothing else
///   - word:   the name appears on token boundaries ("light 1" inside "turn
///             light 1 on") — the normal case
///   - sub:    one contains the other ("living room" said for "Living Room
///             Lamp"). Weakest, and only trusted when nothing better scored,
///             because short names are substrings of long ones.
double matchDevice(String transcript, VoiceDevice device) {
  final label = norm(device.label);
  final raw = norm(device.deviceName);
  if (label.isEmpty && raw.isEmpty) return 0;

  // Speech recognizers return number *words* ("one", "two") rather than the
  // *digits* the device names use ("Socket 1"). Without this, "turn on socket
  // one" found no numbered device, fell through to the group branch, and turned
  // on every socket — the exact bug reported in the field. The misspelling pass
  // (soket -> socket) is what lets "turn on soket 1 soket 2 and light 1" act on
  // all three instead of just Light 1.
  final t = singularizeDeviceNouns(normalizeDeviceNounMisspellings(
      normalizeAmharicDeviceText(normalizeSpokenNumbers(transcript))));
  if (t.isEmpty) return 0;

  final tTokens = tokens(t);

  double best = 0;
  for (final name in {label, raw}) {
    if (name.isEmpty) continue;
    // Normalise the stored name the same way, so a renamed "Socket One" still
    // matches a spoken "socket 1".
    final nameNorm =
        normalizeAmharicDeviceText(normalizeSpokenNumbers(name));

    if (t == nameNorm) {
      best = best < 1.0 ? 1.0 : best;
      continue;
    }

    final nameTokens = tokens(nameNorm);
    if (hasTokenRun(tTokens, nameTokens)) {
      // Longer names are more specific, so a multi-token match beats a
      // single-token one.
      final score = 0.8 + (nameTokens.length * 0.01);
      if (score > best) best = score;
    }

    // Substring fallback, only for names long enough to be meaningful —
    // and never on token evidence, so a short device name cannot be found
    // inside a longer word.
    if (nameNorm.length >= 4 && t.contains(nameNorm)) {
      if (best < 0.6) best = 0.6;
    }
  }
  return best;
}

/// Score every device against [transcript], best first.
///
/// Exposed (via [DeviceResolver.score]) for the NLU layer, which needs the
/// *runner-up* to detect ambiguity ("I found two bedrooms"). [parseVoiceIntent]
/// keeps its own single-best loop so its behaviour — and its tests — are
/// unchanged.
List<DeviceMatch> scoreDevices(String transcript, List<VoiceDevice> devices) {
  final matches = <DeviceMatch>[];
  for (final d in devices) {
    final score = matchDevice(transcript, d);
    if (score > 0) matches.add(DeviceMatch(d, score));
  }
  matches.sort((a, b) => b.score.compareTo(a.score));
  return matches;
}

/// Plural device nouns → the singular form the firmware names use.
///
/// "turn on sockets 1 socket 2" used to match Socket 2 but NOT Socket 1: the
/// token run "socket 1" never appears inside "sockets 1", so the first device of
/// a pluralised list was silently dropped.
///
/// Applied on the device-matching path only — class detection must still see the
/// plural it relies on ("turn on all lights" has to stay a group action).
const Map<String, String> _pluralNouns = {
  'sockets': 'socket',
  'lights': 'light',
  'lamps': 'lamp',
  'outlets': 'outlet',
  'plugs': 'plug',
  'bulbs': 'bulb',
  'fans': 'fan',
  'switches': 'switch',
};

/// Singularise plural device nouns so "sockets 1" matches the name "Socket 1".
String singularizeDeviceNouns(String s) {
  final toks = tokens(s);
  if (toks.isEmpty) return norm(s);
  var changed = false;
  for (var i = 0; i < toks.length; i++) {
    final singular = _pluralNouns[toks[i]];
    if (singular != null) {
      toks[i] = singular;
      changed = true;
    }
  }
  return changed ? toks.join(' ') : norm(s);
}

// ---------------------------------------------------------------------------
// Device-class detection
// ---------------------------------------------------------------------------

const List<String> _amLightNoun = ['መብራት', 'መብራቶች', 'ብርሃን', 'ብርሃኖች', 'ላምፕ'];
const List<String> _amSocketNoun = ['ሶኬት', 'ሶኬቶች', 'መዘርጋት', 'መዘርጋቶች'];

/// Which device class does the transcript name, if any?
///
/// Latin nouns are only recognised when [latinDeviceTokens] is set, for the same
/// reason Latin verbs are: in Amharic mode the device names are Latin too, so a
/// Latin transcript would make every utterance look like a light command.
String? detectGroup(String t,
    {required bool amharic, required bool latinDeviceTokens}) {
  // Rewrite device-noun misspellings first ("soket" -> "socket", "lite" ->
  // "light") so a class query spoken with the recognizer's usual typo still
  // resolves to the right class instead of falling through to "everything".
  // Amharic tokens pass through untouched (no rewrite), so the Amharic class
  // nouns below are unaffected.
  final normT = normalizeDeviceNounMisspellings(t);
  final lights = containsAny(normT, _amLightNoun) ||
      (latinDeviceTokens && containsAny(normT, const ['light', 'lamp']));
  final sockets = containsAny(normT, _amSocketNoun) ||
      (latinDeviceTokens && containsAny(normT, const ['socket', 'outlet', 'plug']));
  if (lights && sockets) return 'all';
  if (lights) return 'lights';
  if (sockets) return 'sockets';
  return null;
}

// ---------------------------------------------------------------------------
// The resolver facade
// ---------------------------------------------------------------------------

/// Resolves a spoken transcript to the best-matching device(s).
///
/// Language- and verb-agnostic: it only does name/class matching against the
/// supplied device list. The parser and the NLU layer both use this so
/// device-name logic lives in exactly one place.
class DeviceResolver {
  const DeviceResolver();

  /// Score every device against [transcript], best first.
  List<DeviceMatch> score(String transcript, List<VoiceDevice> devices) =>
      scoreDevices(transcript, devices);

  /// Best match plus the runner-up, for ambiguity detection.
  ///
  /// Returns up to two matches (best and second). The NLU layer uses the gap
  /// between them to decide whether to ask "which one?".
  ({DeviceMatch? best, DeviceMatch? runnerUp}) resolve(
    String transcript,
    List<VoiceDevice> devices,
  ) {
    final scored = scoreDevices(transcript, devices);
    if (scored.isEmpty) return (best: null, runnerUp: null);
    if (scored.length == 1) return (best: scored.first, runnerUp: null);
    return (best: scored.first, runnerUp: scored[1]);
  }

  /// Which device class the transcript names, if any.
  String? group(String transcript,
          {required bool amharic, required bool latinDeviceTokens}) =>
      detectGroup(transcript,
          amharic: amharic, latinDeviceTokens: latinDeviceTokens);
}
