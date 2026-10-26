// =============================================================================
// Amharic + English voice regression corpus (Phase 3, Plan §D.9 / §E.2)
// =============================================================================
// A single, curated set of utterances — both scripts, group / device / scene /
// guard cases — that the recognizer is expected to parse into the right intent.
// These are the cases that actually bit during development; keeping them in one
// place means a regression in the parser OR the resolver shows up here first,
// before it reaches a phone.
//
// Every expectation below is mirrored from an already-passing unit test
// (voice_intent_test, command_nlu_test, device_resolver_test) so this file is a
// stable reference rather than a new source of behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/robi/domain/voice_command.dart';
import 'package:she_mobile/features/robi/domain/command_nlu.dart';

/// The real names the R24 device profile exposes (device_profiles.c):
/// channels 0-7 = Light 1-8, 8-15 = Socket 1-8, 16-23 = Light 9-16.
List<VoiceDevice> r24() => [
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
      for (var i = 1; i <= 8; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 's$i', deviceName: 'Socket $i'),
      for (var i = 9; i <= 16; i++)
        VoiceDevice(nodeId: 'n1', deviceId: 'l$i', deviceName: 'Light $i'),
    ];

VoiceDevice dev(String name) => VoiceDevice(
      nodeId: 'node-1',
      deviceId: 'id-${name.replaceAll(' ', '-').toLowerCase()}',
      deviceName: name,
    );

void main() {
  group('Amharic group actions (Ethiopic script)', () {
    test('"ሰበኣ መብራት አብር" -> all lights on', () {
      final i = parseVoiceIntent('ሰበኣ መብራት አብር', devices: r24());
      expect(i.action, VoiceAction.turnAllOn);
      expect(i.group, 'lights');
    });
    test('"ሁሉም መብራት አጥፋ" -> all lights off', () {
      final i = parseVoiceIntent('ሁሉም መብራት አጥፋ', devices: r24());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'lights');
    });
    test('"ሁሉም ሶኬት አጥፋ" -> all sockets off', () {
      final i = parseVoiceIntent('ሁሉም ሶኬት አጥፋ', devices: r24());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'sockets');
    });
    test('plural imperative አብሩ + Ethiopic word space U+1361', () {
      expect(parseVoiceIntent('መብራቶች አብሩ', devices: r24()).action,
          VoiceAction.turnAllOn);
      expect(parseVoiceIntent('መብራት፡አብር', devices: r24()).action,
          VoiceAction.turnAllOn);
    });
  });

  group('English / Latin group actions', () {
    test('"turn off all the lights" -> lights off', () {
      final i = parseVoiceIntent('turn off all the lights', devices: r24());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'lights');
    });
    test('both classes named -> group "all"', () {
      final i = parseVoiceIntent('turn off all lights and sockets',
          devices: r24());
      expect(i.action, VoiceAction.turnAllOff);
      expect(i.group, 'all');
    });
  });

  group('specific-device commands', () {
    test('"turn off light 1" -> Light 1 (not all lights)', () {
      final i = parseVoiceIntent('turn off light 1', devices: r24());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Light 1');
    });
    test('"light 1 on" works without the word "turn"', () {
      final i = parseVoiceIntent('light 1 on', devices: r24());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });
    test('"Light 1" does not match inside "Light 12"', () {
      final devices = [
        const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1'),
        const VoiceDevice(nodeId: 'n', deviceId: 'b', deviceName: 'Light 12'),
      ];
      expect(parseVoiceIntent('turn on light 12', devices: devices)
          .device?.deviceName, 'Light 12');
    });
    test('"close socket 3" -> Socket 3 off', () {
      final i = parseVoiceIntent('close socket 3', devices: r24());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Socket 3');
    });
  });

  group('Amharic device-name suffix handling', () {
    final amharicDevices = [
      const VoiceDevice(
        nodeId: 'n1',
        deviceId: 'd1',
        deviceName: 'Light 10',
        displayName: 'የልጆች ክፍል',
      ),
    ];
    test('object marker -ን still matches', () {
      final i = parseVoiceIntent('የልጆች ክፍልን አብር',
          devices: amharicDevices, latinDeviceTokens: false);
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.displayName, 'የልጆች ክፍል');
    });
    test('the bare name still matches', () {
      final i = parseVoiceIntent('የልጆች ክፍል አብር',
          devices: amharicDevices, latinDeviceTokens: false);
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.displayName, 'የልጆች ክፍል');
    });
  });

  group('scenes', () {
    const scenes = [
      VoiceScene(id: 'sc1', name: 'Movie Night'),
      VoiceScene(id: 'sc2', name: 'Good Morning'),
    ];
    test('"activate movie night" -> sc1', () {
      final i = parseVoiceIntent('activate movie night',
          devices: r24(), scenes: scenes);
      expect(i.action, VoiceAction.activateScene);
      expect(i.sceneId, 'sc1');
    });
  });

  group('guards — must NOT fire a command', () {
    test('bare "turn" is unknown', () {
      expect(parseVoiceIntent('turn', devices: r24()).isUnknown, isTrue);
    });
    test('unrelated speech is unknown', () {
      expect(parseVoiceIntent('what is the weather tomorrow', devices: r24())
          .isUnknown, isTrue);
    });
    test('empty transcript is unknown', () {
      expect(parseVoiceIntent('', devices: r24()).isUnknown, isTrue);
      expect(parseVoiceIntent('   ', devices: r24()).isUnknown, isTrue);
    });
    test('Latin transcript in Amharic mode must not match Latin device names',
        () {
      expect(
          parseVoiceIntent('light one on',
                  devices: r24(), latinDeviceTokens: false)
              .isUnknown,
          isTrue);
    });
  });

  group('NLU confidence & ambiguity (commandNlu)', () {
    final devices = [dev('Light 1'), dev('Light 2'), dev('Socket 1')];
    test('a clear device command is high-confidence and unambiguous', () {
      final r = commandNlu.interpret('turn off light 1', devices: devices);
      expect(r.action, VoiceAction.turnOff);
      expect(r.device?.deviceName, 'Light 1');
      expect(r.confidence, greaterThanOrEqualTo(0.8));
      expect(r.isAmbiguous, isFalse);
    });
    test('two boards with the same name are ambiguous', () {
      final twins = [
        const VoiceDevice(nodeId: 'a', deviceId: 'a-1', deviceName: 'Light 1'),
        const VoiceDevice(nodeId: 'b', deviceId: 'b-1', deviceName: 'Light 1'),
      ];
      final r = commandNlu.interpret('turn on light 1', devices: twins);
      expect(r.isAmbiguous, isTrue);
      expect(r.candidates.length, 2);
    });
  });
}
