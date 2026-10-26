// =============================================================================
// Tests for the voice intent parser — verbs, groups, scenes, describe().
// =============================================================================
// The parser is pure Dart precisely so it can be tested here without a phone,
// a microphone or a recognizer. These cases are the ones that actually bit
// during development, plus the real R24 device names.
//
// Device-NAME matching (which "Light 1" resolves to, Amharic suffixes, the
// display-name rename) moved to `device_resolver_test.dart` (change plan
// §D.5); this file keeps the verb / group / scene / describe behaviour.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/voice_intent.dart';
import 'package:she_mobile/features/robi/domain/custom_voice_command.dart';

/// The real names the R24 device profile exposes (device_profiles.c):
/// channels 0-7 = Light 1-8, 8-15 = Socket 1-8, 16-23 = Light 9-16.
List<VoiceDevice> r24Devices() => [
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 's$i', deviceName: 'Socket $i'),
      for (var i = 9; i <= 16; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
    ];

void main() {
  group('Amharic (Ethiopic script)', () {
    test('"ሰበኣ መብራት አብር" turns the light on', () {
      final i = parseVoiceIntent('ሰበኣ መብራት አብር', devices: const []);
      expect(i.action, VoiceAction.turnAllOn);
      expect(i.group, 'lights');
    });

    test('"ሁሉም መብራት አጥፋ" turns all lights off', () {
      final i = parseVoiceIntent('ሁሉም መብራት አጥፋ', devices: const []);
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'lights');
    });

    test('"ሁሉም ሶኬት አጥፋ" turns all sockets off', () {
      final i = parseVoiceIntent('ሁሉም ሶኬት አጥፋ', devices: const []);
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'sockets');
    });

    test('plural imperative አብሩ is recognised', () {
      final i = parseVoiceIntent('መብራቶች አብሩ', devices: const []);
      expect(i.action, VoiceAction.turnAllOn);
    });

    test('Ethiopic word space U+1361 separates tokens', () {
      final i = parseVoiceIntent('መብራት፡አብር', devices: const []);
      expect(i.action, VoiceAction.turnAllOn);
    });

    test('"ሶኬት አንድ ክፈት" targets Socket 1 (single device)', () {
      final i = parseVoiceIntent('ሶኬት አንድ ክፈት', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('"መብራት ሁለት አጥፋ" targets Light 2', () {
      final i = parseVoiceIntent('መብራት ሁለት አጥፋ', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Light 2');
    });
  });

  group('English / Latin', () {
    test('"turn off all the lights" is the group action', () {
      final i = parseVoiceIntent('turn off all the lights', devices: r24Devices());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'lights');
    });

    test('naming both classes yields group "all"', () {
      final i = parseVoiceIntent('turn off all lights and sockets',
          devices: r24Devices());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'all');
    });
  });

  group('guards', () {
    test('bare "turn" is NOT treated as a verb or a device', () {
      // Regression guard: adding "turn"/"the" to the verb table would make this
      // fire a command on a transcript containing no action word at all.
      final i = parseVoiceIntent('turn', devices: r24Devices());
      expect(i.isUnknown, isTrue);
    });

    test('a Latin transcript in Amharic mode must not match Latin device names',
        () {
      // Android has no `am` locale code, so am-ET recognition can fall back to a
      // Latin transcript. In that mode the device names are Latin too, so
      // trusting them would match almost any English utterance and fire a
      // command the speaker never gave.
      final i = parseVoiceIntent(
        'light one on',
        devices: r24Devices(),
        latinDeviceTokens: false,
      );
      expect(i.isUnknown, isTrue);
    });

    test('spoken "light one" resolves to Light 1 (not all lights)', () {
      final i = parseVoiceIntent(
        'turn on light one',
        devices: r24Devices(),
        latinDeviceTokens: true,
      );
      // Speech recognizers return the number as a word; it must still match the
      // digit-named device instead of degrading to the whole class.
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });

    test('"turn on socket one" targets Socket 1, not all sockets', () {
      final i = parseVoiceIntent(
        'turn on socket one',
        devices: r24Devices(),
        latinDeviceTokens: true,
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('"turn off light two" targets Light 2', () {
      final i = parseVoiceIntent(
        'turn off light two',
        devices: r24Devices(),
        latinDeviceTokens: true,
      );
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Light 2');
    });

    test('empty transcript is unknown', () {
      expect(parseVoiceIntent('', devices: r24Devices()).isUnknown, isTrue);
      expect(parseVoiceIntent('   ', devices: r24Devices()).isUnknown, isTrue);
    });

    test('unrelated speech is unknown, not a random command', () {
      final i = parseVoiceIntent('what is the weather tomorrow',
          devices: r24Devices());
      expect(i.isUnknown, isTrue);
    });

    test('"off, no wait, on" resolves to the last polarity said', () {
      final i = parseVoiceIntent('light 1 off no wait on', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });
  });

  group('scenes', () {
    const scenes = [
      VoiceScene(id: 'sc1', name: 'Movie Night'),
      VoiceScene(id: 'sc2', name: 'Good Morning'),
    ];

    test('"activate movie night" activates the scene', () {
      final i = parseVoiceIntent('activate movie night',
          devices: r24Devices(), scenes: scenes);
      expect(i.action, VoiceAction.activateScene);
      expect(i.sceneId, 'sc1');
    });

    test('scene activation beats the "night"-like device noise', () {
      final i = parseVoiceIntent('movie night', devices: r24Devices(), scenes: scenes);
      // No scene verb, and "movie night" is not a device: unknown is correct.
      expect(i.action, VoiceAction.unknown);
    });

    test('a device named in the same breath as a scene wins when specific', () {
      final i = parseVoiceIntent(
        'turn on light 1',
        devices: r24Devices(),
        scenes: scenes,
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });
  });

  group('describe()', () {
    test('renders a readable summary for feedback', () {
      final i = parseVoiceIntent('turn off light 1', devices: r24Devices());
      expect(i.describe(), 'Turn off Light 1');
    });

    test('unknown describes itself', () {
      expect(const VoiceIntent.unknown().describe(), "Didn't understand");
    });
  });

  group('groups & automations', () {
    const groups = [
      VoiceGroup(id: 'g1', name: 'Living Room', deviceIds: ['l1', 's1']),
    ];
    const automations = [
      VoiceAutomation(id: 'a1', name: 'Morning Routine'),
      VoiceAutomation(id: 'a2', name: 'Good Night'),
    ];

    test('"turn on living room" targets the group', () {
      final i = parseVoiceIntent(
        'turn on living room',
        devices: r24Devices(),
        groups: groups,
      );
      expect(i.action, VoiceAction.turnOnGroup);
      expect(i.deviceGroup?.name, 'Living Room');
    });

    test('"turn off living room lights" targets the group, not all lights', () {
      final i = parseVoiceIntent(
        'turn off living room lights',
        devices: r24Devices(),
        groups: groups,
      );
      expect(i.action, VoiceAction.turnOffGroup);
      expect(i.deviceGroup?.name, 'Living Room');
    });

    test('"turn on all lights" stays a class command', () {
      final i = parseVoiceIntent(
        'turn on all lights',
        devices: r24Devices(),
        groups: groups,
      );
      expect(i.action, VoiceAction.turnAllOn);
    });

    test('a device name still beats a same-named group', () {
      final i = parseVoiceIntent(
        'turn on light 1',
        devices: r24Devices(),
        groups: const [
          VoiceGroup(id: 'g', name: 'Light 1', deviceIds: ['x']),
        ],
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });

    test('"run morning routine" runs the automation', () {
      final i = parseVoiceIntent(
        'run morning routine',
        devices: r24Devices(),
        automations: automations,
      );
      expect(i.action, VoiceAction.runAutomation);
      expect(i.automation?.name, 'Morning Routine');
    });

    test('"enable morning routine" enables it', () {
      final i = parseVoiceIntent(
        'enable morning routine',
        devices: r24Devices(),
        automations: automations,
      );
      expect(i.action, VoiceAction.enableAutomation);
    });

    test('"disable good night" disables it', () {
      final i = parseVoiceIntent(
        'disable good night',
        devices: r24Devices(),
        automations: automations,
      );
      expect(i.action, VoiceAction.disableAutomation);
      expect(i.automation?.name, 'Good Night');
    });

    test('a scene beats a same-named automation', () {
      final i = parseVoiceIntent(
        'run movie night',
        devices: r24Devices(),
        scenes: const [VoiceScene(id: 'sc', name: 'Movie Night')],
        automations: const [VoiceAutomation(id: 'a', name: 'Movie Night')],
      );
      expect(i.action, VoiceAction.activateScene);
    });
  });

  group('custom commands', () {
    test('a custom phrase maps to its action', () {
      final i = parseVoiceIntent(
        'make it cozy',
        devices: r24Devices(),
        customCommands: const [
          CustomVoiceCommand(
            id: 'c1',
            phrase: 'make it cozy',
            action: 'turnAllOn',
            group: 'lights',
          ),
        ],
      );
      expect(i.action, VoiceAction.turnAllOn);
      expect(i.group, 'lights');
    });

    test('a custom alias resolves a device by name', () {
      final i = parseVoiceIntent(
        'socket one',
        devices: r24Devices(),
        customCommands: const [
          CustomVoiceCommand(
            id: 'c2',
            phrase: 'socket one',
            action: 'turnOn',
            deviceName: 'Socket 1',
          ),
        ],
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('a locked custom command carries the lock', () {
      final i = parseVoiceIntent(
        'goodnight',
        devices: r24Devices(),
        customCommands: const [
          CustomVoiceCommand(
            id: 'c3',
            phrase: 'goodnight',
            action: 'turnAllOff',
            group: 'all',
            locked: true,
          ),
        ],
      );
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.locked, isTrue);
    });

    test('a disabled custom command is ignored', () {
      final i = parseVoiceIntent(
        'goodnight',
        devices: r24Devices(),
        customCommands: const [
          CustomVoiceCommand(
            id: 'c4',
            phrase: 'goodnight',
            action: 'turnAllOff',
            enabled: false,
          ),
        ],
      );
      expect(i.isUnknown, isTrue);
    });

    test('a custom command with a missing target does not match', () {
      final i = parseVoiceIntent(
        'socket nine',
        devices: r24Devices(),
        customCommands: const [
          CustomVoiceCommand(
            id: 'c5',
            phrase: 'socket nine',
            action: 'turnOn',
            deviceName: 'Socket 9',
          ),
        ],
      );
      // Socket 9 does not exist, so the command cannot resolve; the built-in
      // parser then sees no verb and returns unknown.
      expect(i.isUnknown, isTrue);
    });
  });

  group('more phrasings (verb synonyms)', () {
    test('"switch on socket 1" works', () {
      final i = parseVoiceIntent('switch on socket 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('"power off light 2" works', () {
      final i = parseVoiceIntent('power off light 2', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Light 2');
    });

    test('"start socket 1" works', () {
      final i = parseVoiceIntent('start socket 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('"shut down socket 1" works', () {
      final i = parseVoiceIntent('shut down socket 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('a verb is not matched inside another word ("phone")', () {
      expect(parseVoiceIntent('phone', devices: r24Devices()).isUnknown, isTrue);
    });

    test('"turn on the living room group" targets the group', () {
      final i = parseVoiceIntent(
        'turn on the living room group',
        devices: r24Devices(),
        groups: const [
          VoiceGroup(id: 'g1', name: 'Living Room', deviceIds: ['l1']),
        ],
      );
      expect(i.action, VoiceAction.turnOnGroup);
      expect(i.deviceGroup?.name, 'Living Room');
    });
  });

  group('multi-device commands', () {
    test('"turn on socket 1 and 2" targets both sockets', () {
      final i = parseVoiceIntent(
        'turn on socket 1 and 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Socket 2']);
    });

    test('"turn on socket 1 and light 2" targets both kinds', () {
      final i = parseVoiceIntent(
        'turn on socket 1 and light 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Light 2']);
    });

    test('"turn off socket 1, socket 2 and light 3" targets all three', () {
      final i = parseVoiceIntent(
        'turn off socket 1, socket 2 and light 3',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOff);
      expect(i.devices.map((d) => d.deviceName),
          ['Socket 1', 'Socket 2', 'Light 3']);
    });

    test('Amharic "ሶኬት አንድ እና መብራት ሁለት ክፈት" targets both', () {
      final i = parseVoiceIntent(
        'ሶኬት አንድ እና መብራት ሁለት ክፈት',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Light 2']);
    });

    test('a single-device command still yields exactly one target', () {
      final i = parseVoiceIntent('turn on socket 1', devices: r24Devices());
      expect(i.devices.length, 1);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('a space-separated list still resolves every device', () {
      // norm() turns the comma into a space, so a comma list arrives as ONE
      // segment — each segment must be scanned for every device it names.
      final i = parseVoiceIntent(
        'turn off socket 1 socket 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOff);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Socket 2']);
    });

    test('"&" also separates devices', () {
      final i = parseVoiceIntent(
        'turn on socket 1 & socket 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Socket 2']);
    });

    test('two same-named devices collapse to one target', () {
      // Voice cannot tell them apart, so both must NOT fire — one target is
      // kept, which lets the NLU ask "which one?".
      final twins = [
        const VoiceDevice(
            nodeId: 'a', deviceId: 'a-1', deviceName: 'Socket 1'),
        const VoiceDevice(
            nodeId: 'b', deviceId: 'b-1', deviceName: 'Socket 1'),
      ];
      final i = parseVoiceIntent('turn on socket 1', devices: twins);
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.length, 1);
    });

    test('an unknown device in the list is simply skipped', () {
      final i = parseVoiceIntent(
        'turn on socket 1 and socket 99',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1']);
    });
  });

  group('state questions', () {
    test('"is socket 1 on" asks instead of acting', () {
      final i = parseVoiceIntent('is socket 1 on', devices: r24Devices());
      expect(i.action, VoiceAction.queryState);
      expect(i.device?.deviceName, 'Socket 1');
    });

    test('"which lights are on" asks about the class', () {
      final i = parseVoiceIntent(
        'which lights are on',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.queryState);
      expect(i.group, 'lights');
    });

    test('"whats on" asks about everything', () {
      final i = parseVoiceIntent('whats on', devices: r24Devices());
      expect(i.action, VoiceAction.queryState);
      expect(i.group, 'all');
    });

    test('a non-state question is not swallowed', () {
      final i = parseVoiceIntent(
        'what is the weather tomorrow',
        devices: r24Devices(),
      );
      expect(i.isUnknown, isTrue);
    });

    test('a question about a named group asks about that group', () {
      final i = parseVoiceIntent(
        'is the living room on',
        devices: r24Devices(),
        groups: const [
          VoiceGroup(id: 'g1', name: 'Living Room', deviceIds: ['l1']),
        ],
      );
      expect(i.action, VoiceAction.queryState);
      expect(i.deviceGroup?.name, 'Living Room');
    });

    test('a command is never mistaken for a question', () {
      final i = parseVoiceIntent('turn on socket 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
    });
  });

  group('brightness', () {
    test('"dim light 1" sets a low level, not the device number', () {
      final i = parseVoiceIntent('dim light 1', devices: r24Devices());
      expect(i.action, VoiceAction.setBrightness);
      expect(i.devices.map((d) => d.deviceName), ['Light 1']);
      expect(i.level, 30);
    });

    test('"brighten light 2" sets a high level', () {
      final i = parseVoiceIntent('brighten light 2', devices: r24Devices());
      expect(i.action, VoiceAction.setBrightness);
      expect(i.level, 70);
    });

    test('"set light 1 to 50 percent" uses the spoken level', () {
      final i = parseVoiceIntent(
        'set light 1 to 50 percent',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.setBrightness);
      expect(i.level, 50);
    });

    test('multi-device dimming targets both', () {
      final i = parseVoiceIntent(
        'dim light 1 and light 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.setBrightness);
      expect(i.devices.map((d) => d.deviceName), ['Light 1', 'Light 2']);
      expect(i.level, 30);
    });
  });

  // ---------------------------------------------------------------------------
  // Digit homophones. The recognizer writes "two" as "to" and "four" as "for"
  // on the LE6, which used to fall through to the class noun: "is socket to on"
  // answered about every socket, and "turn on socket for" switched them all on.
  // ---------------------------------------------------------------------------
  group('digit homophones', () {
    test('"is socket to on" is Socket 2, not every socket', () {
      final i = parseVoiceIntent('is socket to on', devices: r24Devices());
      expect(i.action, VoiceAction.queryState);
      expect(i.devices.map((d) => d.deviceName), ['Socket 2']);
    });

    test('"turn on socket for" is Socket 4, not all sockets', () {
      final i = parseVoiceIntent('turn on socket for', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 4']);
    });

    test('"turn on light ate" is Light 8', () {
      final i = parseVoiceIntent('turn on light ate', devices: r24Devices());
      expect(i.devices.map((d) => d.deviceName), ['Light 8']);
    });

    test('"for" after "and" completes the list', () {
      final i = parseVoiceIntent(
        'turn on socket 1 and for',
        devices: r24Devices(),
      );
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Socket 4']);
    });

    test('a preposition before a level is NOT read as a digit', () {
      // "to 50" must stay a brightness level, not become "Light 2".
      final i = parseVoiceIntent(
        'set light 1 to 50 percent',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.setBrightness);
      expect(i.devices.map((d) => d.deviceName), ['Light 1']);
      expect(i.level, 50);
    });
  });

  // ---------------------------------------------------------------------------
  // Plural device nouns. "sockets 1" never contains the token run "socket 1",
  // so the FIRST device of a pluralised list was silently dropped — reported as
  // "turn on socket 1 socket 2 and light 1 turns on only socket 1 and light 1".
  // ---------------------------------------------------------------------------
  group('plural device nouns', () {
    test('"turn on sockets 1 socket 2" keeps BOTH sockets', () {
      final i = parseVoiceIntent(
        'turn on sockets 1 socket 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Socket 1', 'Socket 2']);
    });

    test('"turn on sockets 1 socket 2 and light 1" keeps all three', () {
      final i = parseVoiceIntent(
        'turn on sockets 1 socket 2 and light 1',
        devices: r24Devices(),
      );
      expect(
        i.devices.map((d) => d.deviceName),
        ['Socket 1', 'Socket 2', 'Light 1'],
      );
    });

    test('"turn on all lights" is still a group action, not a device', () {
      final i = parseVoiceIntent('turn on all lights', devices: r24Devices());
      expect(i.action, VoiceAction.turnAllOn);
      expect(i.group, 'lights');
      expect(i.devices, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // "end" is how the recognizer spells the conjunction "and". It used to be an
  // OFF verb, so a turn-ON command was executed as turn-OFF — measured on the
  // LE6: heard="turn on light one light to end light for" -> action=turnOff.
  // ---------------------------------------------------------------------------
  group('"end" as a conjunction', () {
    test('does not flip a turn-on command to turn-off', () {
      final i = parseVoiceIntent(
        'turn on light one light to end light for',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(
        i.devices.map((d) => d.deviceName),
        ['Light 1', 'Light 2', 'Light 4'],
      );
    });

    test('separates the device list like "and"', () {
      final i = parseVoiceIntent(
        'turn on light 1 end light 2',
        devices: r24Devices(),
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.devices.map((d) => d.deviceName), ['Light 1', 'Light 2']);
    });

    test('a real "turn off" still works', () {
      final i = parseVoiceIntent('turn off light 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.devices.map((d) => d.deviceName), ['Light 1']);
    });
  });
}
