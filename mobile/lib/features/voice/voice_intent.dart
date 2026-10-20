// =============================================================================
// SHE V3 — Voice intent parser
// =============================================================================
// Turns a speech transcript into a device command. Pure Dart: no Flutter, no
// plugins, no network — so it can be unit tested without a phone or a
// recognizer, which is the whole reason it lives in its own file.
//
// V3-VOICE-MATTER §1-2. The firmware path (Picovoice on the R16) is Phase 4C and
// still a stub; this is the phone-side path, which works on every SKU because
// the recognition happens on the handset and only the resulting API call leaves
// the device.
//
// ---------------------------------------------------------------------------
// A note on language and script
// ---------------------------------------------------------------------------
// The app ships Amharic-first (see app_router's localeProvider), so the primary
// target is Amharic utterances. Two things shape the design:
//
//  1. We ask the recogniser for `am-ET` when the app is in Amharic, so the
//     transcript comes back in Ethiopic script. That is what the Amharic verbs
//     below match.
//
//  2. Android has no `am` locale CODE, so when on-device `am-ET` recognition is
//     unavailable speech_to_text falls back to an English locale and the
//     transcript arrives transliterated in Latin letters ("sabaa salon birhan
//     abr"). We cannot reliably parse that: Amharic's ejective consonants
//     (ብርሃን, አብር) have no agreed Latin spelling, so any transliteration table
//     would be guesswork.
//
// The caller therefore passes `latinDeviceTokens: false` in Amharic mode. This
// matters for correctness, not just tidiness: the device names are Latin
// ("Light 1"), so a Latin transcript in Amharic mode would match the device
// name on almost any English-sounding utterance and fire a command the user
// never asked for. English device tokens are only trusted when we actually
// asked for an English recogniser.
// =============================================================================

/// What the user asked for.
enum VoiceAction {
  turnOn,
  turnOff,

  /// "turn off all the lights" / "ሁሉም መብራት አጥፋ" — the whole class, atomically.
  turnAllOn,
  turnAllOff,

  activateScene,

  /// Heard something, understood nothing. Worth showing back to the user rather
  /// than silently doing nothing.
  unknown,
}

/// A device the user could refer to. Kept independent of the API's map shape
/// so the parser has no dependency on the service layer.
class VoiceDevice {
  final String nodeId;
  final String deviceId;
  final String deviceName;

  /// User-set rename. Preferred over [deviceName] for matching, because that is
  /// the name the user sees and therefore the one they will say.
  final String? displayName;

  const VoiceDevice({
    required this.nodeId,
    required this.deviceId,
    required this.deviceName,
    this.displayName,
  });

  /// What the UI shows and what the user says.
  String get label =>
      (displayName != null && displayName!.trim().isNotEmpty)
          ? displayName!.trim()
          : deviceName;
}

/// A parsed command, ready to execute.
class VoiceIntent {
  final VoiceAction action;

  /// Set for single-device actions; null for the whole-class and scene actions.
  final VoiceDevice? device;

  /// For the class actions: 'lights' | 'sockets' | 'all' — the group vocabulary
  /// the backend's group_set and the firmware's RELAY_GROUP_*_R24 masks share.
  final String? group;

  /// Set for [VoiceAction.activateScene].
  final String? sceneId;

  /// Score of the winning parse. Exposed so the UI can be honest about a weak
  /// match instead of pretending it understood.
  final double confidence;

  const VoiceIntent({
    required this.action,
    this.device,
    this.group,
    this.sceneId,
    this.confidence = 1.0,
  });

  const VoiceIntent.unknown({this.confidence = 0.0})
      : action = VoiceAction.unknown,
        device = null,
        group = null,
        sceneId = null;

  bool get isUnknown => action == VoiceAction.unknown;

  /// Human-readable description of what we understood — shown as feedback so a
  /// misheard command is visible instead of mysterious.
  String describe() {
    switch (action) {
      case VoiceAction.turnOn:
        return 'Turn on ${device?.label ?? '?'}';
      case VoiceAction.turnOff:
        return 'Turn off ${device?.label ?? '?'}';
      case VoiceAction.turnAllOn:
        return 'Turn on all $_groupLabel';
      case VoiceAction.turnAllOff:
        return 'Turn off all $_groupLabel';
      case VoiceAction.activateScene:
        return 'Activate scene';
      case VoiceAction.unknown:
        return "Didn't understand";
    }
  }

  String get _groupLabel => switch (group) {
        'lights' => 'lights',
        'sockets' => 'sockets',
        _ => 'devices',
      };
}

/// A scene the user could refer to.
class VoiceScene {
  final String id;
  final String name;
  const VoiceScene({required this.id, required this.name});
}

/// A device and how well the transcript matched it.
class DeviceMatch {
  final VoiceDevice device;
  final double score;
  const DeviceMatch(this.device, this.score);
}

/// Score every device against [transcript], best first.
///
/// Exposed for the NLU layer, which needs the *runner-up* to detect ambiguity
/// ("I found two bedrooms"). [parseVoiceIntent] keeps its own single-best loop
/// so its behaviour — and its tests — are unchanged.
List<DeviceMatch> scoreDevices(String transcript, List<VoiceDevice> devices) {
  final matches = <DeviceMatch>[];
  for (final d in devices) {
    final score = _matchDevice(transcript, d);
    if (score > 0) matches.add(DeviceMatch(d, score));
  }
  matches.sort((a, b) => b.score.compareTo(a.score));
  return matches;
}

// ---------------------------------------------------------------------------
// Grammar tables
// ---------------------------------------------------------------------------

/// Amharic ON verbs. These are imperatives (the form a person actually speaks
/// to a device), plus the polite/plural variants.
///
///   አብር      abr      "light up" (masc. sg. imperative)
///   አብሪ      abri     (fem. sg.)
///   አብሩ      abru     (plural / polite)
///   አብሪው     abriw
///   ክፈት      kifet    "open" — used for sockets/switches
///   አስጀምር     asjemir  "start"
///   አብራ       abra
///   ላይ አድርግ   lay adrig
const List<String> _amOn = [
  'አብር', 'አብሪ', 'አብሩ', 'አብሪው', 'ክፈት', 'ክፈቱ', 'አስጀምር', 'አብራ', 'ላይ አድርግ',
];

/// Amharic OFF verbs.
///
///   አጥፋ   atfa   "extinguish" (masc. sg.)
///   አጥፊ   atfi   (fem. sg.)
///   አጥፉ   atfu   (plural / polite)
///   አጥፊው  atfiw
///   ዝጋ    ziga   "close"
///   አቁም   akum   "stop"
///   አጥበው  atbew
const List<String> _amOff = [
  'አጥፋ', 'አጥፊ', 'አጥፉ', 'አጥፊው', 'ዝጋ', 'ዝጉ', 'አቁም', 'አቁሚ', 'አጥበው',
];

/// "all" / "everything".
const List<String> _amAll = ['ሁሉም', 'ሁሉንም', 'ሁሉ', 'ሁሉን', 'በሙሉ', 'ሙሉ'];

/// Device-class nouns.
const List<String> _amLightNoun = ['መብራት', 'መብራቶች', 'ብርሃን', 'ብርሃኖች', 'ላምፕ'];
const List<String> _amSocketNoun = ['ሶኬት', 'ሶኬቶች', 'መዘርጋት', 'መዘርጋቶች'];

/// Latin ON/OFF verbs we trust.
///
/// Deliberately short. "on"/"off" are included because they are unambiguous
/// action words ("turn off the light" / "light off"). Bare "turn" and "the" are
/// NOT: device names contain no such words today, but treating a common English
/// function word as a verb is exactly how a parser grows false positives, and
/// speakers already carry the meaning in "on"/"off".
const List<String> _enOn = ['on', 'enable', 'open'];
const List<String> _enOff = ['off', 'disable', 'close'];

const List<String> _enAll = ['all', 'every', 'everything'];

/// Scene activation verbs. "set" is intentionally absent — "set the light on"
/// is a device command, and "set" would swallow it.
const List<String> _enSceneVerb = ['activate', 'run', 'start', 'execute', 'scene'];
const List<String> _amSceneVerb = ['አስኪድ', 'ጀምር', 'ስንቄ', 'ሲኒ'];

// ---------------------------------------------------------------------------
// Matching helpers
// ---------------------------------------------------------------------------

/// Normalise for comparison: lowercase, collapse whitespace, strip punctuation
/// that recognizers like to append ("Light 1." / "መብራት።").
///
/// Note the character class is built with a non-raw string on purpose: a raw
/// string (`r'...'`) cannot contain the escaped apostrophe, so writing it as
/// `r'[...\'...]'` leaves a literal backslash before the quote and the string
/// never terminates — a compile error, not a runtime surprise.
String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp("[.,!?\u1362\u1363\u1364\u1365:;\"'\u2019\u201C\u201D()\\[\\]]"), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Split into tokens on whitespace. Amharic uses U+1361 (፡) as a word space, so
/// treat that as whitespace too.
List<String> _tokens(String s) =>
    _norm(s).split(RegExp(r'[\s\u1361]+')).where((t) => t.isNotEmpty).toList();

bool _containsAny(String haystack, List<String> needles) {
  for (final n in needles) {
    if (haystack.contains(n)) return true;
  }
  return false;
}

/// Does [transcript] refer to [device]?
///
/// Returns a score, higher is better, 0 for no match. Three tiers, because the
/// failure modes differ:
///   - exact:  the user named the device and nothing else
///   - word:   the name appears on token boundaries ("light 1" inside "turn
///             light 1 on") — the normal case
///   - sub:    one contains the other ("living room" said for "Living Room
///             Lamp"). Weakest, and only trusted when nothing better scored,
///             because short names are substrings of long ones.
/// Match [name] against the transcript's tokens at word boundaries.
///
/// Returns true if every token of [name] appears contiguously in [tTokens].
/// Comparing tokens rather than substrings is what keeps "Light 1" from
/// matching inside "Light 12".
bool _hasTokenRun(List<String> tTokens, List<String> nameTokens) {
  if (nameTokens.isEmpty || nameTokens.length > tTokens.length) return false;
  for (var i = 0; i + nameTokens.length <= tTokens.length; i++) {
    var all = true;
    for (var j = 0; j < nameTokens.length; j++) {
      if (tTokens[i + j] != nameTokens[j]) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

double _matchDevice(String transcript, VoiceDevice device) {
  final label = _norm(device.label);
  final raw = _norm(device.deviceName);
  if (label.isEmpty && raw.isEmpty) return 0;

  final t = _norm(transcript);
  if (t.isEmpty) return 0;

  final tTokens = _tokens(t);

  double best = 0;
  for (final name in {label, raw}) {
    if (name.isEmpty) continue;

    if (t == name) {
      best = best < 1.0 ? 1.0 : best;
      continue;
    }

    final nameTokens = _tokens(name);
    if (_hasTokenRun(tTokens, nameTokens)) {
      // Longer names are more specific, so a multi-token match beats a
      // single-token one.
      final score = 0.8 + (nameTokens.length * 0.01);
      if (score > best) best = score;
    }

    // Substring fallback, only for names long enough to be meaningful —
    // and never on token evidence, so a short device name cannot be found
    // inside a longer word.
    if (name.length >= 4 && t.contains(name)) {
      if (best < 0.6) best = 0.6;
    }
  }
  return best;
}

/// Which device class does the transcript name, if any?
///
/// Latin nouns are only recognised when [latinDeviceTokens] is set, for the same
/// reason Latin verbs are: in Amharic mode the device names are Latin too, so a
/// Latin transcript would make every utterance look like a light command.
String? _detectGroup(String t, {required bool amharic, required bool latinDeviceTokens}) {
  final lights = _containsAny(t, _amLightNoun) ||
      (latinDeviceTokens && _containsAny(t, const ['light', 'lamp']));
  final sockets = _containsAny(t, _amSocketNoun) ||
      (latinDeviceTokens && _containsAny(t, const ['socket', 'outlet', 'plug']));
  if (lights && sockets) return 'all';
  if (lights) return 'lights';
  if (sockets) return 'sockets';
  return null;
}

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

/// Parse [transcript] into a [VoiceIntent].
///
/// [devices] and [scenes] are the current home's contents — the parser resolves
/// names against real data rather than any hardcoded list, so a rename in the
/// app immediately changes what the user can say.
///
/// [latinDeviceTokens] must be true only when the transcript is genuinely
/// English (see the file header).
VoiceIntent parseVoiceIntent(
  String transcript, {
  required List<VoiceDevice> devices,
  List<VoiceScene> scenes = const [],
  bool latinDeviceTokens = true,
  bool amharic = true,
}) {
  final t = _norm(transcript);
  if (t.isEmpty) return const VoiceIntent.unknown();

  // ---- 1. Verb ----------------------------------------------------------
  // Amharic verbs are always trusted: the Ethiopic script cannot collide with
  // the Latin device names.
  final hasAmOn = _containsAny(t, _amOn);
  final hasAmOff = _containsAny(t, _amOff);
  // Latin verbs only when we asked for a Latin recogniser.
  final hasEnOn = latinDeviceTokens && _containsAny(t, _enOn);
  final hasEnOff = latinDeviceTokens && _containsAny(t, _enOff);

  // If both polarities somehow match ("light off, no wait on"), the LAST one
  // wins, because that is what the speaker most recently decided.
  int lastIndexOf(List<String> needles) {
    var idx = -1;
    for (final n in needles) {
      final i = t.lastIndexOf(n);
      if (i > idx) idx = i;
    }
    return idx;
  }

  final onIdx = [
    if (hasAmOn) lastIndexOf(_amOn),
    if (hasEnOn) lastIndexOf(_enOn),
  ].fold<int>(-1, (a, b) => b > a ? b : a);
  final offIdx = [
    if (hasAmOff) lastIndexOf(_amOff),
    if (hasEnOff) lastIndexOf(_enOff),
  ].fold<int>(-1, (a, b) => b > a ? b : a);

  final bool? on;
  if (onIdx < 0 && offIdx < 0) {
    on = null;
  } else if (offIdx < 0) {
    on = true;
  } else if (onIdx < 0) {
    on = false;
  } else {
    on = onIdx > offIdx;
  }

  // ---- 2. Explicit scene activation -------------------------------------
  // Checked before the device scan so a scene named "Movie Night" is not
  // mistaken for a device, and only when a scene verb is present.
  final hasSceneVerb =
      _containsAny(t, _amSceneVerb) || (latinDeviceTokens && _containsAny(t, _enSceneVerb));

  if (scenes.isNotEmpty) {
    // A scene only activates when the user said an activation verb. Without
    // one, "Movie Night" said on its own is not a command — a scene named like
    // a room should not fire because the room was mentioned. This also keeps
    // scene resolution from pre-empting the device scan.
    if (hasSceneVerb) {
      double bestScene = 0;
      VoiceScene? bestMatch;
      for (final s in scenes) {
        final name = _norm(s.name);
        if (name.isEmpty) continue;
        double score = 0;
        if (t == name) {
          score = 1.0;
        } else if (t.contains(name)) {
          score = 0.9;
        } else if (name.length >= 4 && _hasTokenRun(_tokens(t), _tokens(name))) {
          score = 0.7;
        }
        if (score > bestScene) {
          bestScene = score;
          bestMatch = s;
        }
      }
      if (bestMatch != null && bestScene >= 0.9) {
        return VoiceIntent(
          action: VoiceAction.activateScene,
          sceneId: bestMatch.id,
          confidence: bestScene,
        );
      }
    }
  }

  // ---- 3. Group / all ---------------------------------------------------
  final group = _detectGroup(t, amharic: amharic, latinDeviceTokens: latinDeviceTokens);
  final wantsAll = _containsAny(t, _amAll) ||
      (latinDeviceTokens && _containsAny(t, _enAll)) ||
      (on != null && group != null && devices.isEmpty);

  // A device-name match beats a group match ("turn off Light 1" must not
  // become "turn off all lights"), so resolve devices first and only fall back
  // to the group when nothing specific was named.
  double bestDevice = 0;
  VoiceDevice? bestDeviceMatch;
  for (final d in devices) {
    final score = _matchDevice(t, d);
    if (score > bestDevice) {
      bestDevice = score;
      bestDeviceMatch = d;
    }
  }

  if (on != null && bestDevice >= 0.8) {
    return VoiceIntent(
      action: on ? VoiceAction.turnOn : VoiceAction.turnOff,
      device: bestDeviceMatch,
      confidence: bestDevice,
    );
  }

  if (on != null && group != null && (wantsAll || bestDevice < 0.8)) {
    return VoiceIntent(
      action: on ? VoiceAction.turnAllOn : VoiceAction.turnAllOff,
      group: group,
      confidence: 0.85,
    );
  }

  // A weak device match with a verb is still worth acting on.
  if (on != null && bestDevice > 0) {
    return VoiceIntent(
      action: on ? VoiceAction.turnOn : VoiceAction.turnOff,
      device: bestDeviceMatch,
      confidence: bestDevice,
    );
  }

  // ---- 4. Scene without an exact name match -----------------------------
  if (hasSceneVerb && scenes.isNotEmpty) {
    for (final s in scenes) {
      if (t.contains(_norm(s.name))) {
        return VoiceIntent(
          action: VoiceAction.activateScene,
          sceneId: s.id,
          confidence: 0.8,
        );
      }
    }
  }

  return const VoiceIntent.unknown();
}
