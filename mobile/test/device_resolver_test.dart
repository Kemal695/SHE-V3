// =============================================================================
// Tests for the device-name resolver (extracted from the voice parser).
// =============================================================================
// Change plan §D.5: the language- and verb-agnostic half of voice parsing —
// scoring a transcript against the home's device list, Amharic suffix
// handling, token-run matching and device-class detection — now lives in
// `device_resolver.dart`. These tests cover that module directly (unit) and
// through `parseVoiceIntent` (integration), proving the extraction changed no
// behaviour. The verb / group / scene / describe behaviour stays in
// `voice_intent_test.dart`.
// =============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/robi/domain/device_resolver.dart';
import 'package:she_mobile/features/robi/domain/voice_command.dart';

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
  group('DeviceResolver — direct unit tests', () {
    test('norm lowercases and strips trailing punctuation', () {
      expect(norm('Light 1.'), 'light 1');
      expect(norm('  TURN  ON  '), 'turn on');
    });

    test('tokens splits on whitespace and the Ethiopic word space U+1361', () {
      expect(tokens('light 1'), ['light', '1']);
      expect(tokens('መብራት፡አብር'), ['መብራት', 'አብር']);
    });

    test('matchDevice gives an exact name 1.0', () {
      final d = const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1');
      expect(matchDevice('light 1', d), 1.0);
    });

    test('matchDevice scores a token run at or above 0.8', () {
      final d = const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1');
      final s = matchDevice('turn off light 1', d);
      expect(s, greaterThanOrEqualTo(0.8));
    });

    test('matchDevice scores a long-name containment at or above 0.6', () {
      final d =
          const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Bedroom Lamp');
      final s = matchDevice('the bedroom lamp is on', d);
      expect(s, greaterThanOrEqualTo(0.6));
    });

    test('normalizeSpokenNumbers maps cardinal words to digits', () {
      expect(normalizeSpokenNumbers('turn on socket one'), 'turn on socket 1');
      expect(normalizeSpokenNumbers('light two'), 'light 2');
      expect(normalizeSpokenNumbers('no numbers here'), 'no numbers here');
    });

    test('matchDevice pairs spoken number words with digit device names', () {
      final socket1 =
          const VoiceDevice(nodeId: 'n', deviceId: 's1', deviceName: 'Socket 1');
      final light2 =
          const VoiceDevice(nodeId: 'n', deviceId: 'l2', deviceName: 'Light 2');
      expect(matchDevice('turn on socket one', socket1),
          greaterThanOrEqualTo(0.8));
      expect(matchDevice('turn off light two', light2),
          greaterThanOrEqualTo(0.8));
    });

    test('number-word match still respects token boundaries (1 not 12)', () {
      final light1 =
          const VoiceDevice(nodeId: 'n', deviceId: 'l1', deviceName: 'Light 1');
      final light12 =
          const VoiceDevice(nodeId: 'n', deviceId: 'l12', deviceName: 'Light 12');
      expect(matchDevice('turn on light one', light1), greaterThan(0));
      // "one" maps to "1", which must not spill into "Light 12".
      expect(matchDevice('turn on light one', light12), 0);
    });

    test('scoreDevices sorts best-first and includes the runner-up', () {
      // Two boards each exposing "Light 1" — the real ambiguity case where a
      // runner-up must exist so the NLU layer can ask "which one?".
      final devices = [
        const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1'),
        const VoiceDevice(nodeId: 'n', deviceId: 'b', deviceName: 'Light 1'),
      ];
      final scored = scoreDevices('turn on light 1', devices);
      expect(scored.first.device.deviceName, 'Light 1');
      expect(scored.length, 2);
    });

    test('DeviceResolver.resolve returns best and runner-up', () {
      final devices = [
        const VoiceDevice(nodeId: 'n', deviceId: 'a', deviceName: 'Light 1'),
        const VoiceDevice(nodeId: 'n', deviceId: 'b', deviceName: 'Light 1'),
      ];
      final r = const DeviceResolver().resolve('turn on light 1', devices);
      expect(r.best?.device.deviceName, 'Light 1');
      expect(r.runnerUp?.device.deviceName, 'Light 1');
    });

    test('tokenMatches is exact or a known Amharic suffix only', () {
      expect(tokenMatches('ክፍል', 'ክፍል'), isTrue);
      expect(tokenMatches('ክፍል', 'ክፍልን'), isTrue); // object marker -ን
      expect(tokenMatches('ክፍል', 'ክፍልት'), isFalse); // must not fabricate a word
    });

    test('hasTokenRun matches contiguous tokens only', () {
      expect(hasTokenRun(['light', '12'], ['light', '1']), isFalse);
      expect(hasTokenRun(['turn', 'light', '1', 'on'], ['light', '1']), isTrue);
    });

    test('detectGroup names the device class in Amharic', () {
      expect(detectGroup('መብራት አብር', amharic: true, latinDeviceTokens: false),
          'lights');
      expect(detectGroup('ሶኬት አጥፋ', amharic: true, latinDeviceTokens: false),
          'sockets');
      expect(detectGroup('መብራት ሶኬት አጥፋ', amharic: true, latinDeviceTokens: false),
          'all');
    });

    test('detectGroup only trusts Latin nouns when latinDeviceTokens is set', () {
      expect(
          detectGroup('turn on the light',
              amharic: false, latinDeviceTokens: true),
          'lights');
      expect(
          detectGroup('turn on the light',
              amharic: true, latinDeviceTokens: false),
          isNull);
    });
  });

  // The integration cases below are the parser-level device-name scenarios,
  // kept here so the resolver is proven through the real entry point too.
  group('device-name resolution (via parser)', () {
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

    test('"close the socket 3" is a socket off', () {
      final i = parseVoiceIntent('close socket 3', devices: r24Devices());
      expect(i.action, VoiceAction.turnOff);
      expect(i.device?.deviceName, 'Socket 3');
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

  // Amharic nouns take a suffix when spoken ("ክፍል" -> "ክፍልን"), which exact token
  // matching rejected. These are the natural phrasings, not invented ones.
  group('Amharic noun suffixes', () {
    final amharicDevices = [
      const VoiceDevice(
        nodeId: 'n1',
        deviceId: 'd1',
        deviceName: 'Light 10',
        displayName: 'የልጆች ክፍል',
      ),
      const VoiceDevice(
        nodeId: 'n1',
        deviceId: 'd2',
        deviceName: 'Light 11',
        displayName: 'መኝታ ቤት',
      ),
    ];

    test('object marker -ን still matches the stored name', () {
      final i = parseVoiceIntent(
        'የልጆች ክፍልን አብር',
        devices: amharicDevices,
        latinDeviceTokens: false,
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.displayName, 'የልጆች ክፍል');
    });

    test('the bare name still matches', () {
      final i = parseVoiceIntent(
        'የልጆች ክፍል አብር',
        devices: amharicDevices,
        latinDeviceTokens: false,
      );
      expect(i.action, VoiceAction.turnOn);
      expect(i.device?.displayName, 'የልጆች ክፍል');
    });

    test('the same suffix rule applies to the OFF verb', () {
      final i = parseVoiceIntent(
        'የልጆች ክፍልን አጥፋ',
        devices: amharicDevices,
        latinDeviceTokens: false,
      );
      expect(i.device?.displayName, 'የልጆች ክፍል');
      expect(i.action, VoiceAction.turnOff);
    });

    test('a Latin name is unaffected by the Amharic suffix rule', () {
      final i = parseVoiceIntent('turn off light 1', devices: r24Devices());
      expect(i.device?.deviceName, 'Light 1');
      expect(i.action, VoiceAction.turnOff);
    });
  });
}
