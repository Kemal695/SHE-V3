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

import 'device_resolver.dart';
import 'custom_voice_command.dart';

/// What the user asked for.
enum VoiceAction {
  turnOn,
  turnOff,

  /// "turn off all the lights" / "ሁሉም መብራት አጥፋ" — the whole class, atomically.
  turnAllOn,
  turnAllOff,

  /// "turn on the living room" — a user-defined device group, by name.
  turnOnGroup,
  turnOffGroup,

  activateScene,

  /// "run morning routine" / "trigger …" — execute an automation's actions now.
  runAutomation,

  /// "enable morning routine" / "turn on morning routine".
  enableAutomation,

  /// "disable morning routine" / "turn off morning routine".
  disableAutomation,

  /// Ask about state instead of changing it — "is socket 1 on?",
  /// "which lights are on?", "what's on?".
  queryState,

  /// Set a level — "dim light 1", "set light 1 to 50 percent".
  setBrightness,

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

  /// Every device this command targets. A single-device command has exactly one
  /// entry; "socket 1 and light 2" has two. [device] is the first of these.
  final List<VoiceDevice> devices;

  /// For the class actions: 'lights' | 'sockets' | 'all' — the group vocabulary
  /// the backend's group_set and the firmware's RELAY_GROUP_*_R24 masks share.
  final String? group;

  /// Set for [VoiceAction.activateScene].
  final String? sceneId;

  /// Set for [VoiceAction.turnOnGroup] / [VoiceAction.turnOffGroup].
  final VoiceGroup? deviceGroup;

  /// Set for [VoiceAction.runAutomation] / [VoiceAction.enableAutomation] /
  /// [VoiceAction.disableAutomation].
  final VoiceAutomation? automation;

  /// Score of the winning parse. Exposed so the UI can be honest about a weak
  /// match instead of pretending it understood.
  final double confidence;

  /// True when this came from a user command marked "locked": the safety policy
  /// forces a confirmation before it runs.
  final bool locked;

  /// True when this came from a user-defined custom command. The ambiguity check
  /// is skipped for these: the user already picked the exact target, so a phrase
  /// like "turn on the light" must not become "which one?".
  final bool fromCustom;

  /// For [VoiceAction.setBrightness]: 0..100.
  final int? level;

  const VoiceIntent({
    required this.action,
    this.devices = const [],
    this.group,
    this.sceneId,
    this.deviceGroup,
    this.automation,
    this.confidence = 1.0,
    this.locked = false,
    this.fromCustom = false,
    this.level,
  });

  const VoiceIntent.unknown({this.confidence = 0.0})
      : action = VoiceAction.unknown,
        devices = const [],
        group = null,
        sceneId = null,
        deviceGroup = null,
        automation = null,
        locked = false,
        fromCustom = false,
        level = null;

  bool get isUnknown => action == VoiceAction.unknown;

  /// The first target, or null when none. Kept so existing single-device callers
  /// keep working unchanged.
  VoiceDevice? get device => devices.isEmpty ? null : devices.first;

  /// "Socket 1", or "Socket 1, Socket 2" for a multi-device command.
  String get _targetLabel =>
      devices.isEmpty ? '?' : devices.map((d) => d.label).join(', ');

  /// Human-readable description of what we understood — shown as feedback so a
  /// misheard command is visible instead of mysterious.
  String describe() {
    switch (action) {
      case VoiceAction.turnOn:
        return 'Turn on $_targetLabel';
      case VoiceAction.turnOff:
        return 'Turn off $_targetLabel';
      case VoiceAction.turnAllOn:
        return 'Turn on all $_groupLabel';
      case VoiceAction.turnAllOff:
        return 'Turn off all $_groupLabel';
      case VoiceAction.turnOnGroup:
        return 'Turn on ${deviceGroup?.name ?? 'group'}';
      case VoiceAction.turnOffGroup:
        return 'Turn off ${deviceGroup?.name ?? 'group'}';
      case VoiceAction.activateScene:
        return 'Activate scene';
      case VoiceAction.runAutomation:
        return 'Run ${automation?.name ?? 'automation'}';
      case VoiceAction.enableAutomation:
        return 'Enable ${automation?.name ?? 'automation'}';
      case VoiceAction.disableAutomation:
        return 'Disable ${automation?.name ?? 'automation'}';
      case VoiceAction.queryState:
        if (devices.length == 1) return 'Check ${devices.first.label}';
        final g = deviceGroup;
        if (g != null) return 'Check ${g.name}';
        return 'Check $_groupLabel';
      case VoiceAction.setBrightness:
        return 'Set $_targetLabel to ${level ?? '?'}%';
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

/// A user-defined device group (backend `node_groups`).
///
/// Turning one on/off switches every member, exactly like the group's master
/// button on the Devices tab. Members are DEVICE IDS, resolved against the
/// home's device list at execution time.
class VoiceGroup {
  final String id;
  final String name;
  final List<String> deviceIds;

  const VoiceGroup({
    required this.id,
    required this.name,
    required this.deviceIds,
  });
}

/// An automation the user could run / enable / disable by name.
class VoiceAutomation {
  final String id;
  final String name;
  final bool enabled;

  const VoiceAutomation({
    required this.id,
    required this.name,
    this.enabled = true,
  });
}

/// A device and how well the transcript matched it.
class DeviceMatch {
  final VoiceDevice device;
  final double score;
  const DeviceMatch(this.device, this.score);
}

// `scoreDevices` now lives in `device_resolver.dart` (change plan §D.5); the NLU
// layer imports it from there. [parseVoiceIntent] below keeps its own
// single-best loop so its behaviour — and its tests — are unchanged.

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
  'አብር', 'አብሪ', 'አብሩ', 'አብሪው', 'አብራ', 'አብራራ',
  'ክፈት', 'ክፈቱ',
  'አስጀምር', 'አስጀምሩ', 'አስጀምሪ',
  'ላይ አድርግ',
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
  'አጥፋ', 'አጥፊ', 'አጥፉ', 'አጥፊው', 'አጥፋው',
  'ዝጋ', 'ዝጉ', 'ዘግተው',
  'አቁም', 'አቁሚ', 'አቁሙ',
  'አጥበው',
];

/// "all" / "everything".
const List<String> _amAll = ['ሁሉም', 'ሁሉንም', 'ሁሉ', 'ሁሉን', 'በሙሉ', 'ሙሉ'];

/// Latin ON/OFF verbs.
///
/// Broad on purpose — different customers phrase the same intent many ways
/// ("switch on", "power on", "fire up", "shut down"). Matching is WHOLE-TOKEN
/// (see _hasVerbToken), so a word like "on" no longer matches inside "phone",
/// which is what makes a broad list safe. "turn" and "the" are still excluded.
const List<String> _enOn = [
  'on', 'enable', 'open', 'start', 'activate', 'resume', 'begin', 'boot',
  'turn on', 'switch on', 'power on', 'put on', 'fire up', 'light up',
];
const List<String> _enOff = [
  'off', 'disable', 'close', 'stop', 'shut', 'pause', 'deactivate',
  'turn off', 'switch off', 'power off', 'shut off', 'shut down', 'cut off',
];
// NOTE: "end" is deliberately NOT an off verb. Recognizers spell the conjunction
// "and" as "end" ("light one end light two"), and with "end" in this list a
// turn-ON command was parsed as turn-OFF — measured on the LE6:
//   heard="turn on light one light to end light for" -> action=turnOff
// "and" is handled as a list separator instead (see _resolveTargets).

const List<String> _enAll = ['all', 'every', 'everything'];

/// Question words. A transcript with one of these and NO on/off verb is a state
/// question ("is socket 1 on?"), not a command.
const List<String> _enQuestion = [
  'is', 'are', 'what', 'whats', 'which', 'status', 'state', 'check', 'tell',
];
const List<String> _amQuestion = ['ነው', 'ናት', 'ምን', 'የት', 'ስንት'];

/// Brightness verbs, with the level each implies when no number is spoken.
const List<String> _enDim = ['dim', 'lower', 'reduce', 'darken'];
const List<String> _enBrighten = ['brighten', 'brighter', 'raise', 'increase'];

/// Scene activation verbs. "set" is intentionally absent — "set the light on"
/// is a device command, and "set" would swallow it.
const List<String> _enSceneVerb = ['activate', 'run', 'start', 'execute', 'scene'];
const List<String> _amSceneVerb = ['አስኪድ', 'ጀምር', 'ስንቄ', 'ሲኒ'];

/// Automation "run" verbs. Overlaps the scene verbs because a scene and an
/// automation are both "runnable"; the parser checks scenes first, then
/// automations, so a same-named scene wins.
const List<String> _enRunVerb = ['run', 'trigger', 'start', 'execute', 'activate'];
const List<String> _amRunVerb = ['አስኪድ', 'ጀምር', 'ስንቄ', 'ሲኒ'];

// ---------------------------------------------------------------------------
// Device-name matching — see device_resolver.dart
// ---------------------------------------------------------------------------
// The language- and verb-agnostic matching half (norm / tokens / containsAny /
// tokenMatches / hasTokenRun / matchDevice / scoreDevices / detectGroup) was
// extracted to `device_resolver.dart` (change plan §D.5) so the parser and the
// NLU layer share one implementation. This file keeps the verb tables and the
// parser. The parser below calls the public helpers from `device_resolver`.

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
  List<VoiceGroup> groups = const [],
  List<VoiceAutomation> automations = const [],
  List<CustomVoiceCommand> customCommands = const [],
  bool latinDeviceTokens = true,
  bool amharic = true,
}) {
  final t = norm(transcript);
  if (t.isEmpty) return const VoiceIntent.unknown();

  // ---- 0. User-defined custom commands --------------------------------
  // Checked FIRST so a custom phrase can override a built-in one (that is what
  // makes "socket one" work as an alias even before the number-word fix, and
  // lets "goodnight" mean whatever the user mapped it to).
  if (customCommands.isNotEmpty) {
    CustomVoiceCommand? best;
    double bestScore = 0;
    for (final c in customCommands) {
      if (!c.enabled) continue;
      final phrase = norm(c.phrase);
      if (phrase.isEmpty) continue;
      double score = 0;
      if (t == phrase) {
        score = 1.0;
      } else if (phrase.length >= 3 && t.contains(phrase)) {
        score = 0.95;
      } else if (phrase.length >= 3 && hasTokenRun(tokens(t), tokens(phrase))) {
        score = 0.9;
      }
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    if (best != null && bestScore >= 0.9) {
      final intent =
          _intentFromCustom(best, devices, groups, scenes, automations);
      if (intent != null) return intent;
    }
  }

  // ---- 0b. State question ------------------------------------------------
  // Checked BEFORE verb detection, so the "on" in "is socket 1 on?" is not read
  // as a command. Answering instead of acting is the difference between an
  // assistant and a remote control.
  final isQuestion = (amharic && containsAny(t, _amQuestion)) ||
      (latinDeviceTokens && _hasVerbToken(t, _enQuestion));
  if (isQuestion) {
    final q = _queryTarget(
      t,
      devices,
      groups,
      amharic: amharic,
      latinDeviceTokens: latinDeviceTokens,
    );
    if (q != null) return q;
  }

  // ---- 1. Verb ----------------------------------------------------------
  // Amharic verbs are always trusted: the Ethiopic script cannot collide with
  // the Latin device names.
  final hasAmOn = containsAny(t, _amOn);
  final hasAmOff = containsAny(t, _amOff);
  // Latin verbs only when we asked for a Latin recogniser — and matched on WHOLE
  // TOKENS, so a broad verb list cannot fire inside another word ("on" inside
  // "phone").
  final hasEnOn = latinDeviceTokens && _hasVerbToken(t, _enOn);
  final hasEnOff = latinDeviceTokens && _hasVerbToken(t, _enOff);

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

  // ---- 2b. Brightness ----------------------------------------------------
  // "dim light 1" / "brighten light 2" / "set light 1 to 50 percent". None of
  // these carries an on/off verb.
  if (on == null && latinDeviceTokens) {
    final dim = _hasVerbToken(t, _enDim);
    final brighten = _hasVerbToken(t, _enBrighten);
    // An explicit level is enough on its own: "set light 1 to 50 percent".
    final explicit = _hasVerbToken(t, const ['percent', 'to']) || t.contains('%');
    if (dim || brighten || explicit) {
      final targets = _resolveTargets(t, devices);
      if (targets.isNotEmpty) {
        return VoiceIntent(
          action: VoiceAction.setBrightness,
          devices: targets,
          // The device's OWN number must never be read as a level, so "dim
          // light 1" means 30%, not 1%.
          level: (explicit ? _levelFrom(t) : null) ?? (dim ? 30 : 70),
          confidence: 0.8,
        );
      }
    }
  }

  // ---- 2. Explicit scene activation -------------------------------------
  // Checked before the device scan so a scene named "Movie Night" is not
  // mistaken for a device, and only when a scene verb is present.
  final hasSceneVerb =
      containsAny(t, _amSceneVerb) || (latinDeviceTokens && containsAny(t, _enSceneVerb));
  // Automation verbs. "enable"/"disable" are separate from on/off so an
  // automation can be toggled without ambiguity; they are also on/off verbs,
  // which is what makes "turn on morning routine" work.
  final hasRunVerb = containsAny(t, _amRunVerb) ||
      (latinDeviceTokens && containsAny(t, _enRunVerb));
  final hasEnable = latinDeviceTokens && containsAny(t, const ['enable']);
  final hasDisable = latinDeviceTokens && containsAny(t, const ['disable']);

  if (scenes.isNotEmpty) {
    // A scene only activates when the user said an activation verb. Without
    // one, "Movie Night" said on its own is not a command — a scene named like
    // a room should not fire because the room was mentioned. This also keeps
    // scene resolution from pre-empting the device scan.
    if (hasSceneVerb) {
      double bestScene = 0;
      VoiceScene? bestMatch;
      for (final s in scenes) {
        final name = norm(s.name);
        if (name.isEmpty) continue;
        double score = 0;
        if (t == name) {
          score = 1.0;
        } else if (t.contains(name)) {
          score = 0.9;
        } else if (name.length >= 4 && hasTokenRun(tokens(t), tokens(name))) {
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
  final group = detectGroup(t, amharic: amharic, latinDeviceTokens: latinDeviceTokens);
  final wantsAll = containsAny(t, _amAll) ||
      (latinDeviceTokens && containsAny(t, _enAll)) ||
      (on != null && group != null && devices.isEmpty);

  // A device-name match beats a group match ("turn off Light 1" must not
  // become "turn off all lights"), so resolve devices first and only fall back
  // to the group when nothing specific was named.
  double bestDevice = 0;
  VoiceDevice? bestDeviceMatch;
  for (final d in devices) {
    final score = matchDevice(t, d);
    if (score > bestDevice) {
      bestDevice = score;
      bestDeviceMatch = d;
    }
  }

  if (on != null && bestDevice >= 0.8) {
    final targets = _resolveTargets(t, devices);
    return VoiceIntent(
      action: on ? VoiceAction.turnOn : VoiceAction.turnOff,
      // Resolve EVERY device named, so "socket 1 and 2", "socket 1 and light 2"
      // and "socket 1, socket 2 and light 3" each act on all of them. Falls back
      // to the best single match when nothing splittable resolved.
      devices: targets.isNotEmpty
          ? targets
          : (bestDeviceMatch == null ? const [] : [bestDeviceMatch]),
      confidence: bestDevice,
    );
  }

  // A user-defined GROUP ("Living Room") beats the class nouns ("lights") when
  // it matches by name, so "turn on living room lights" targets that group
  // rather than every light in the home.
  if (on != null && groups.isNotEmpty) {
    final m = _bestNamed(t, groups.map((g) => g.name).toList());
    if (m != null && m.score >= 0.8) {
      final g = groups.firstWhere((x) => x.name == m.name);
      return VoiceIntent(
        action: on ? VoiceAction.turnOnGroup : VoiceAction.turnOffGroup,
        deviceGroup: g,
        confidence: m.score,
      );
    }
  }

  if (on != null && group != null && (wantsAll || bestDevice < 0.8)) {
    return VoiceIntent(
      action: on ? VoiceAction.turnAllOn : VoiceAction.turnAllOff,
      group: group,
      confidence: 0.85,
    );
  }

  // Automations: "run/trigger <name>", "enable/disable <name>", or
  // "turn on/off <name>". Checked AFTER devices and groups, so a device or
  // group that shares the name wins.
  if (automations.isNotEmpty) {
    final m = _bestNamed(t, automations.map((a) => a.name).toList());
    if (m != null && m.score >= 0.8) {
      final a = automations.firstWhere((x) => x.name == m.name);
      VoiceAction? act;
      if (hasEnable) {
        act = VoiceAction.enableAutomation;
      } else if (hasDisable) {
        act = VoiceAction.disableAutomation;
      } else if (hasRunVerb) {
        act = VoiceAction.runAutomation;
      } else if (on == true) {
        act = VoiceAction.enableAutomation;
      } else if (on == false) {
        act = VoiceAction.disableAutomation;
      }
      if (act != null) {
        return VoiceIntent(
          action: act,
          automation: a,
          confidence: m.score,
        );
      }
    }
  }

  // A weak device match with a verb is still worth acting on.
  if (on != null && bestDevice > 0) {
    return VoiceIntent(
      action: on ? VoiceAction.turnOn : VoiceAction.turnOff,
      devices: bestDeviceMatch == null ? const [] : [bestDeviceMatch],
      confidence: bestDevice,
    );
  }

  // ---- 4. Scene without an exact name match -----------------------------
  if (hasSceneVerb && scenes.isNotEmpty) {
    for (final s in scenes) {
      if (t.contains(norm(s.name))) {
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

/// Build a state-question intent from [t]: a named device, a named group, a
/// class noun, or everything.
///
/// Returns null when the question is not about power state at all ("what is the
/// weather"), so it falls through to the normal command path.
VoiceIntent? _queryTarget(
  String t,
  List<VoiceDevice> devices,
  List<VoiceGroup> groups, {
  required bool amharic,
  required bool latinDeviceTokens,
}) {
  // A named device wins.
  final best = _bestDevice(t, devices);
  if (best != null) {
    return VoiceIntent(
      action: VoiceAction.queryState,
      devices: [best],
      confidence: 0.9,
    );
  }
  // A user-defined group by name.
  for (final g in groups) {
    final name = norm(g.name);
    if (name.isEmpty) continue;
    final hit = t == name ||
        t.contains(name) ||
        (name.length >= 4 && hasTokenRun(tokens(t), tokens(name)));
    if (hit) {
      return VoiceIntent(
        action: VoiceAction.queryState,
        deviceGroup: g,
        confidence: 0.85,
      );
    }
  }
  // A class noun — "which lights are on?".
  final group = detectGroup(t, amharic: amharic, latinDeviceTokens: latinDeviceTokens);
  if (group != null) {
    return VoiceIntent(
      action: VoiceAction.queryState,
      group: group,
      confidence: 0.85,
    );
  }
  // "what's on?" — everything, but only when the question really is about power
  // state, so an unrelated question is not swallowed.
  final mentionsState = _hasVerbToken(t, const [
        'on', 'off', 'open', 'closed', 'power', 'state', 'status',
      ]) ||
      containsAny(t, _amOn) ||
      containsAny(t, _amOff);
  if (!mentionsState) return null;
  return VoiceIntent(
    action: VoiceAction.queryState,
    group: 'all',
    confidence: 0.6,
  );
}

/// The brightness level spoken EXPLICITLY in [t] — the number after "to", or the
/// one next to "percent"/"%". Null when none was said, so the verb's own default
/// applies. Deliberately ignores bare numbers, which are usually the device's
/// own index ("dim light 1" is not 1%).
int? _levelFrom(String t) {
  final toks = tokens(t);
  for (var i = 0; i < toks.length - 1; i++) {
    if (toks[i] == 'to') {
      final n = int.tryParse(toks[i + 1]);
      if (n != null) return n.clamp(0, 100);
    }
  }
  for (var i = 0; i < toks.length; i++) {
    if (toks[i] == 'percent' || toks[i] == '%') {
      for (var j = i - 1; j >= 0; j--) {
        final n = int.tryParse(toks[j]);
        if (n != null) return n.clamp(0, 100);
      }
    }
  }
  return null;
}

/// Best single-device match at or above the 0.8 acting threshold, or null.
VoiceDevice? _bestDevice(String t, List<VoiceDevice> devices) {
  VoiceDevice? best;
  double bestScore = 0;
  for (final d in devices) {
    final s = matchDevice(t, d);
    if (s > bestScore) {
      bestScore = s;
      best = d;
    }
  }
  return bestScore >= 0.8 ? best : null;
}

/// The noun part of a device name — "Socket 1" -> "socket", "Light 2" -> "light".
/// Used to complete a bare trailing number in "socket 1 and 2".
String _nounOf(VoiceDevice d) {
  final full = norm(d.deviceName);
  final toks = tokens(full);
  if (toks.length <= 1) return full;
  final last = toks.last;
  if (RegExp(r'^\d+$').hasMatch(last)) {
    return toks.sublist(0, toks.length - 1).join(' ');
  }
  return full;
}

/// Every device named in [t], at or above the 0.8 acting threshold.
///
/// A segment can name several devices — "turn off socket 1 socket 2" — because
/// [norm] has already turned the comma into a space by the time we get here.
/// Order follows the device list, so the result matches the order spoken.
///
/// Devices that share a NAME are collapsed to one: voice cannot tell them apart,
/// so acting on both would silently switch a device the user never named. Keeping
/// one leaves `devices.length == 1`, which lets the NLU's ambiguity check ask
/// "which one?" instead.
List<VoiceDevice> _devicesIn(String t, List<VoiceDevice> devices) {
  final out = <VoiceDevice>[];
  final seenNames = <String>{};
  for (final d in devices) {
    if (matchDevice(t, d) < 0.8) continue;
    final keys = {norm(d.deviceName), norm(d.label)};
    if (keys.any(seenNames.contains)) continue;
    seenNames.addAll(keys);
    out.add(d);
  }
  return out;
}

/// Resolve EVERY device named in [t] so a multi-device command acts on all of
/// them: "socket 1 and light 2" -> [Socket 1, Light 2], and "socket 1 and 2"
/// -> [Socket 1, Socket 2] (the bare "2" inherits the noun from "socket 1").
///
/// Falls back to the single best match, so ordinary one-device commands are
/// completely unaffected.
///
/// Note: [norm] rewrites `,` `!` `?` `:` `;` `.` into spaces, so a comma list
/// arrives as ONE segment — which is why each segment is scanned for every
/// device it names, not just the best. `&` and `plus` survive norm and are still
/// split on, which keeps the bare-number inheritance working.
List<VoiceDevice> _resolveTargets(String t, List<VoiceDevice> devices) {
  if (devices.isEmpty) return const [];

  final segments = t
      // "end" is how the recognizer usually spells the conjunction "and"
      // ("light one end light two"), so it separates the list — it is not a verb.
      .split(RegExp(r'\s*(?:&|\band\b|\bend\b|\bplus\b)\s*|\s+እና\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  if (segments.length <= 1) return _devicesIn(t, devices);

  final out = <VoiceDevice>[];
  String? noun;
  for (final seg in segments) {
    final found = _devicesIn(seg, devices);
    if (found.isNotEmpty) {
      out.addAll(found);
      noun = _nounOf(found.last);
    } else if (noun != null && noun.isNotEmpty) {
      // A bare trailing number ("... and 2") — complete it with the noun from
      // the previous device.
      out.addAll(_devicesIn('$noun $seg', devices));
    }
  }

  // De-duplicate, preserving order.
  final seen = <String>{};
  return out.where((d) => seen.add(d.deviceId)).toList();
}

/// Whole-token verb check.
///
/// Unlike [containsAny] this never matches a verb INSIDE another word ("on"
/// inside "phone"), which is what makes a broad English verb list safe. Handles
/// both single words ("on") and short phrases ("turn on").
bool _hasVerbToken(String t, List<String> verbs) {
  final toks = tokens(t);
  for (final v in verbs) {
    final vt = tokens(v);
    if (vt.length == 1) {
      if (toks.contains(vt.first)) return true;
    } else if (hasTokenRun(toks, vt)) {
      return true;
    }
  }
  return false;
}

/// Best name match among [names] for transcript [t], or null.
///
/// Same tiers as the scene matcher: exact > containment > token run. Used for
/// user-defined groups and automations, whose names are arbitrary.
({String name, double score})? _bestNamed(String t, List<String> names) {
  double best = 0;
  String? bestName;
  for (final n in names) {
    final name = norm(n);
    if (name.isEmpty) continue;
    double score = 0;
    if (t == name) {
      score = 1.0;
    } else if (name.length >= 4 && t.contains(name)) {
      // Substring only for names long enough to be meaningful. A three-letter
      // automation name ("loc") used to match inside "located" and silently
      // ENABLED that automation — measured: heard="he's located on" ->
      // action=enableAutomation automation="loc".
      score = 0.9;
    } else if (name.length >= 4 && hasTokenRun(tokens(t), tokens(name))) {
      score = 0.85;
    }
    if (score > best) {
      best = score;
      bestName = n;
    }
  }
  if (bestName == null) return null;
  return (name: bestName, score: best);
}

/// Build a [VoiceIntent] from a user's custom command, resolving its stored
/// name/id against the CURRENT devices/groups/scenes/automations. Returns null
/// when the target no longer exists (renamed/deleted), so a stale command is
/// simply not matched instead of acting on the wrong thing.
VoiceIntent? _intentFromCustom(
  CustomVoiceCommand c,
  List<VoiceDevice> devices,
  List<VoiceGroup> groups,
  List<VoiceScene> scenes,
  List<VoiceAutomation> automations,
) {
  VoiceAction? action;
  for (final a in VoiceAction.values) {
    if (a.name == c.action) {
      action = a;
      break;
    }
  }
  if (action == null) return null;

  switch (action) {
    case VoiceAction.turnOn:
    case VoiceAction.turnOff:
      for (final d in devices) {
        if (d.deviceName == c.deviceName || d.label == c.deviceName) {
          return VoiceIntent(
            action: action,
            devices: [d],
            locked: c.locked,
            fromCustom: true,
            confidence: 1.0,
          );
        }
      }
      return null;
    case VoiceAction.turnOnGroup:
    case VoiceAction.turnOffGroup:
      for (final g in groups) {
        if ((c.groupId != null && g.id == c.groupId) ||
            (c.groupName != null && g.name == c.groupName)) {
          return VoiceIntent(
            action: action,
            deviceGroup: g,
            locked: c.locked,
            fromCustom: true,
            confidence: 1.0,
          );
        }
      }
      return null;
    case VoiceAction.turnAllOn:
    case VoiceAction.turnAllOff:
      return VoiceIntent(
        action: action,
        group: c.group ?? 'all',
        locked: c.locked,
        fromCustom: true,
        confidence: 1.0,
      );
    case VoiceAction.activateScene:
      for (final s in scenes) {
        if (s.id == c.sceneId) {
          return VoiceIntent(
            action: action,
            sceneId: s.id,
            locked: c.locked,
            fromCustom: true,
            confidence: 1.0,
          );
        }
      }
      return null;
    case VoiceAction.runAutomation:
    case VoiceAction.enableAutomation:
    case VoiceAction.disableAutomation:
      for (final a in automations) {
        if (a.id == c.automationId) {
          return VoiceIntent(
            action: action,
            automation: a,
            locked: c.locked,
            fromCustom: true,
            confidence: 1.0,
          );
        }
      }
      return null;
    // A question is never something a user maps to a phrase, and brightness is
    // not part of the custom-command editor yet — so these simply never match.
    case VoiceAction.queryState:
    case VoiceAction.setBrightness:
      return null;
    case VoiceAction.unknown:
      return null;
  }
}
