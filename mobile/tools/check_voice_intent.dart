// Standalone harness for voice_intent.dart.
//
// WHY THIS EXISTS: `flutter test` cannot run in the agent shell on this box —
// Flutter's native-asset hooks die with ERROR_PIPE_BUSY 231 before any test
// executes, and `pub get` is killed the same way. That is an environment
// limitation, not a code problem.
//
// voice_intent.dart imports nothing but dart:core, so it can be exercised
// directly with the standalone Dart SDK and no package resolution at all. That
// is the whole reason the parser was kept free of Flutter imports.
//
// Run:
//   dart run tools/check_voice_intent.dart
//
// The full, idiomatic suite lives in test/voice_intent_test.dart and runs under
// `flutter test` on a machine where that works.
import '../lib/features/voice/voice_intent.dart';

int _pass = 0;
int _fail = 0;
final _failures = <String>[];

void check(String name, bool Function() fn) {
  try {
    if (fn()) {
      _pass++;
    } else {
      _fail++;
      _failures.add(name);
    }
  } catch (e) {
    _fail++;
    _failures.add('$name  (threw: $e)');
  }
}

List<VoiceDevice> r24() => [
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 's$i', deviceName: 'Socket $i'),
      for (var i = 9; i <= 16; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
    ];

void main() {
  final d = r24();

  // ---- Amharic ----
  check('am: መብራት አብር -> all lights on', () {
    final i = parseVoiceIntent('መብራት አብር', devices: const []);
    return i.action == VoiceAction.turnAllOn && i.group == 'lights';
  });
  check('am: ሁሉም መብራት አጥፋ -> all lights off', () {
    final i = parseVoiceIntent('ሁሉም መብራት አጥፋ', devices: const []);
    return i.action == VoiceAction.turnAllOff && i.group == 'lights';
  });
  check('am: ሁሉም ሶኬት አጥፋ -> all sockets off', () {
    final i = parseVoiceIntent('ሁሉም ሶኬት አጥፋ', devices: const []);
    return i.action == VoiceAction.turnAllOff && i.group == 'sockets';
  });
  check('am: plural አብሩ recognised', () {
    final i = parseVoiceIntent('መብራቶች አብሩ', devices: const []);
    return i.action == VoiceAction.turnAllOn;
  });
  check('am: U+1361 word space splits tokens', () {
    final i = parseVoiceIntent('መብራት፡አብር', devices: const []);
    return i.action == VoiceAction.turnAllOn;
  });
  check('am: renamed device matched by display name', () {
    final i = parseVoiceIntent('ሳሎን መብራት አብር', devices: [
      const VoiceDevice(
          nodeId: 'n1',
          deviceId: 'l1',
          deviceName: 'Light 1',
          displayName: 'ሳሎን መብራት'),
    ]);
    return i.action == VoiceAction.turnOn && i.device?.deviceId == 'l1';
  });

  // ---- English ----
  check('en: turn off light 1 -> Light 1', () {
    final i = parseVoiceIntent('turn off light 1', devices: d);
    return i.action == VoiceAction.turnOff && i.device?.deviceName == 'Light 1';
  });
  check('en: light 1 on (no "turn")', () {
    final i = parseVoiceIntent('light 1 on', devices: d);
    return i.action == VoiceAction.turnOn && i.device?.deviceName == 'Light 1';
  });
  check('en: Light 1 does not match inside Light 12', () {
    final i = parseVoiceIntent('turn on light 12', devices: [
      const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1'),
      const VoiceDevice(nodeId: 'n', deviceId: 'b', deviceName: 'Light 12'),
    ]);
    return i.device?.deviceName == 'Light 12';
  });
  check('en: turn off all the lights -> group', () {
    final i = parseVoiceIntent('turn off all the lights', devices: d);
    return i.action == VoiceAction.turnAllOff && i.group == 'lights';
  });
  check('en: both classes -> group all', () {
    final i = parseVoiceIntent('turn off all lights and sockets', devices: d);
    return i.action == VoiceAction.turnAllOff && i.group == 'all';
  });
  check('en: close socket 3 -> Socket 3 off', () {
    final i = parseVoiceIntent('close socket 3', devices: d);
    return i.action == VoiceAction.turnOff && i.device?.deviceName == 'Socket 3';
  });

  // ---- Guards ----
  check('guard: bare "turn" is unknown', () {
    return parseVoiceIntent('turn', devices: d).isUnknown;
  });
  check('guard: Latin transcript in Amharic mode does not match devices', () {
    final i = parseVoiceIntent('light one on',
        devices: d, latinDeviceTokens: false);
    return i.isUnknown;
  });
  check('guard: empty transcript unknown', () {
    return parseVoiceIntent('', devices: d).isUnknown &&
        parseVoiceIntent('   ', devices: d).isUnknown;
  });
  check('guard: unrelated speech is unknown', () {
    return parseVoiceIntent('what is the weather tomorrow', devices: d).isUnknown;
  });
  check('guard: last polarity wins ("off no wait on")', () {
    final i = parseVoiceIntent('light 1 off no wait on', devices: d);
    return i.action == VoiceAction.turnOn && i.device?.deviceName == 'Light 1';
  });

  // ---- Scenes ----
  const scenes = [
    VoiceScene(id: 'sc1', name: 'Movie Night'),
    VoiceScene(id: 'sc2', name: 'Good Morning'),
  ];
  check('scene: activate movie night', () {
    final i = parseVoiceIntent('activate movie night',
        devices: d, scenes: scenes);
    return i.action == VoiceAction.activateScene && i.sceneId == 'sc1';
  });
  check('scene: bare "movie night" stays unknown', () {
    final i = parseVoiceIntent('movie night', devices: d, scenes: scenes);
    return i.action == VoiceAction.unknown;
  });
  check('scene: specific device beats scene when both present', () {
    final i = parseVoiceIntent('turn on light 1', devices: d, scenes: scenes);
    return i.action == VoiceAction.turnOn && i.device?.deviceName == 'Light 1';
  });

  // ---- describe ----
  check('describe: turn off Light 1', () {
    final i = parseVoiceIntent('turn off light 1', devices: d);
    return i.describe() == 'Turn off Light 1';
  });
  check('describe: unknown', () {
    return const VoiceIntent.unknown().describe() == "Didn't understand";
  });

  print('PASS $_pass   FAIL $_fail');
  if (_failures.isNotEmpty) {
    print('--- failures ---');
    for (final f in _failures) {
      print('  x $f');
    }
  }
}
