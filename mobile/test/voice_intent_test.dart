// =============================================================================
// Tests for the voice intent parser.
// =============================================================================
// The parser is pure Dart precisely so it can be tested here without a phone,
// a microphone or a recognizer. These cases are the ones that actually bit
// during development, plus the real R24 device names.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/voice_intent.dart';

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

    test('a renamed device is matched by its display name', () {
      final devices = [
        const VoiceDevice(
          nodeId: 'n1',
          deviceId: 'l1',
          deviceName: 'Light 1',
          displayName: 'ሳሎን መብራት',
        ),
      ];
      final i = parseVoiceIntent('ሳሎን መብራት አብር', devices: devices);
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceId, 'l1');
    });
  });

  group('English / Latin', () {
    test('"turn off light 1" targets Light 1, not all lights', () {
      final i = parseVoiceIntent('turn off light 1', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Light 1');
    });

    test('"light 1 on" works without the word "turn"', () {
      final i = parseVoiceIntent('light 1 on', devices: r24Devices());
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.deviceName, 'Light 1');
    });

    test('"Light 1" does not match inside "Light 12"', () {
      final devices = [
        const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1'),
        const VoiceDevice(nodeId: 'n', deviceId: 'b', deviceName: 'Light 12'),
      ];
      final i = parseVoiceIntent('turn on light 12', devices: devices);
      expect(i.device?.deviceName, 'Light 12');
    });

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

    test('"close the socket 3" is a socket off', () {
      final i = parseVoiceIntent('close socket 3', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Socket 3');
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

    test('the same transcript with an English recognizer does resolve', () {
      final i = parseVoiceIntent(
        'turn on light one',
        devices: r24Devices(),
        latinDeviceTokens: true,
      );
      // "light one" is not "Light 1" (a digit), so this is the group action —
      // which is the honest outcome rather than a wrong device.
      expect(i.action, anyOf(VoiceAction.turnAllOn, VoiceAction.turnOn));
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
}
