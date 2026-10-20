// Phase 1 — command NLU + safety policy (spec §5.4, §6, §9).

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/nlu/command_nlu.dart';
import 'package:she_mobile/features/voice/nlu/safety_policy.dart';
import 'package:she_mobile/features/voice/voice_intent.dart';

VoiceDevice dev(String name, {String? display}) => VoiceDevice(
      nodeId: 'node-1',
      deviceId: 'id-${name.replaceAll(' ', '-').toLowerCase()}',
      deviceName: name,
      displayName: display,
    );

NluResult result({
  VoiceAction action = VoiceAction.turnOn,
  VoiceDevice? device,
  String? group,
  double confidence = 0.9,
  List<DeviceMatch> candidates = const [],
  String transcript = 'turn on the light',
}) =>
    NluResult(
      transcript: transcript,
      normalized: transcript.toLowerCase(),
      language: 'en',
      action: action,
      device: device,
      group: group,
      confidence: confidence,
      candidates: candidates,
    );

void main() {
  group('CommandNlu', () {
    final devices = [
      dev('Light 1'),
      dev('Light 2'),
      dev('Socket 1'),
      dev('Bedroom Light'),
      dev('Bedroom Light 2'),
    ];

    test('resolves a specific device and its type', () {
      final r = commandNlu.interpret('turn off light 1', devices: devices);
      expect(r.action, VoiceAction.turnOff);
      expect(r.device?.deviceName, 'Light 1');
      expect(r.deviceType, 'light');
      expect(r.confidence, greaterThanOrEqualTo(0.8));
      expect(r.isAmbiguous, isFalse);
    });

    test('reports the device type for sockets', () {
      final r = commandNlu.interpret('turn on socket 1', devices: devices);
      expect(r.deviceType, 'socket');
    });

    test('a whole-class command has a type but no single device', () {
      final r = commandNlu.interpret('turn off all the lights', devices: devices);
      expect(r.action, VoiceAction.turnAllOff);
      expect(r.group, 'lights');
      expect(r.deviceType, 'light');
      expect(r.isAmbiguous, isFalse);
    });

    test('detects two devices with the same name', () {
      // The real ambiguity: two boards in one home both expose "Light 1", so the
      // transcript identifies a channel but not which board. Robi must ask.
      final twins = [
        const VoiceDevice(
            nodeId: 'node-a', deviceId: 'a-1', deviceName: 'Light 1'),
        const VoiceDevice(
            nodeId: 'node-b', deviceId: 'b-1', deviceName: 'Light 1'),
      ];
      final r = commandNlu.interpret('turn on light 1', devices: twins);
      expect(r.isAmbiguous, isTrue);
      expect(r.candidates.length, 2);
    });

    test('a longer name is not ambiguous with its prefix', () {
      // "Bedroom Light" and "Bedroom Light 2" do NOT tie: the second is not a
      // token run for the utterance "the bedroom light", so no question is
      // needed. This is why the ambiguity window is on scores, not on prefixes.
      final r = commandNlu.interpret(
          'turn on the bedroom light', devices: devices);
      expect(r.isAmbiguous, isFalse);
      expect(r.device?.deviceName, 'Bedroom Light');
    });

    test('language is detected from the transcript', () {
      expect(commandNlu.interpret('መብራት አብር', devices: devices).language, 'am');
      expect(
        commandNlu.interpret('የመኝታ ቤቱን Light 1 አብራ', devices: devices).language,
        'mixed',
      );
    });

    test('unknown text is unknown', () {
      final r = commandNlu.interpret('make me a sandwich', devices: devices);
      expect(r.isUnknown, isTrue);
    });
  });

  group('CommandSafetyPolicy', () {
    const policy = CommandSafetyPolicy();

    test('unknown → reject', () {
      final d = policy.decide(result(action: VoiceAction.unknown, confidence: 0));
      expect(d.decision, Decision.reject);
    });

    test('high confidence and unambiguous → execute', () {
      final d = policy.decide(
        result(device: dev('Light 1'), confidence: 0.95),
      );
      expect(d.decision, Decision.execute);
      expect(d.risk, RiskLevel.low);
    });

    test('mid confidence → clarify with a question', () {
      final d = policy.decide(result(device: dev('Light 1'), confidence: 0.7));
      expect(d.decision, Decision.clarify);
      expect(d.question, contains('Light 1'));
    });

    test('low confidence → reject', () {
      final d = policy.decide(result(device: dev('Light 1'), confidence: 0.3));
      expect(d.decision, Decision.reject);
    });

    test('ambiguity is clarified even at high confidence', () {
      final d = policy.decide(result(
        device: dev('Bedroom Light'),
        confidence: 0.99,
        candidates: [
          DeviceMatch(dev('Bedroom Light'), 0.99),
          DeviceMatch(dev('Bedroom Light 2'), 0.97),
        ],
      ));
      expect(d.decision, Decision.clarify);
      expect(d.question, contains('Bedroom Light'));
    });

    test('group actions are medium risk', () {
      final d = policy.decide(
        result(action: VoiceAction.turnAllOff, group: 'lights', confidence: 0.9),
      );
      expect(d.risk, RiskLevel.medium);
      expect(d.decision, Decision.execute);
    });

    test('scenes are medium risk', () {
      final d = policy.decide(
        result(action: VoiceAction.activateScene, confidence: 0.95),
      );
      expect(d.risk, RiskLevel.medium);
    });

    test('thresholds are configurable', () {
      const strict = CommandSafetyPolicy(autoExecute: 0.99, clarifyFloor: 0.9);
      final d = strict.decide(result(device: dev('Light 1'), confidence: 0.95));
      expect(d.decision, Decision.clarify);
    });
  });
}
