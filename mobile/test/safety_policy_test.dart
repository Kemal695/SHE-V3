// =============================================================================
// Command safety policy tests — high-impact hook + regressions (Phase 4, §D.10)
// =============================================================================
// The policy is the only place thresholds and risk categories live. These tests
// pin the NEW high-impact behaviour (a gate/entrance/lock must always be
// confirmed, even at full confidence) and guard against regressions in the
// existing decisions (unknown -> reject, confident light -> execute).
import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/robi/domain/command_safety_policy.dart';
import 'package:she_mobile/features/robi/domain/command_nlu.dart';
import 'package:she_mobile/features/robi/domain/voice_command.dart';

VoiceDevice dev(String name) => VoiceDevice(
      nodeId: 'node-1',
      deviceId: 'id-${name.replaceAll(' ', '-').toLowerCase()}',
      deviceName: name,
    );

NluResult result({
  VoiceAction action = VoiceAction.turnOn,
  VoiceDevice? device,
  String? group,
  double confidence = 0.9,
}) =>
    NluResult(
      transcript: 'x',
      normalized: 'x',
      language: 'en',
      action: action,
      devices: device == null ? const [] : [device],
      group: group,
      confidence: confidence,
      candidates: const [],
    );

void main() {
  const policy = CommandSafetyPolicy();

  group('high-impact hook (Plan §D.10)', () {
    test('a gate command is high risk -> must be confirmed', () {
      final d = policy.decide(result(device: dev('Gate 1'), confidence: 0.99));
      expect(d.risk, RiskLevel.high);
      expect(d.decision, Decision.clarify);
    });

    test('an entrance at full confidence still cannot skip confirmation', () {
      final d = policy.decide(result(device: dev('Entrance'), confidence: 1.0));
      expect(d.risk, RiskLevel.high);
      expect(d.decision, Decision.clarify);
    });

    test('a normal light at the same confidence is executed', () {
      final d = policy.decide(result(device: dev('Light 1'), confidence: 0.99));
      expect(d.risk, RiskLevel.low);
      expect(d.decision, Decision.execute);
    });

    test('isHighImpact detects the keywords in the device name only', () {
      expect(policy.isHighImpact(result(device: dev('Gate 1'))), isTrue);
      expect(policy.isHighImpact(result(device: dev('Garage Door'))), isTrue);
      expect(policy.isHighImpact(result(device: dev('Light 1'))), isFalse);
      expect(policy.isHighImpact(result(device: dev('Socket 2'))), isFalse);
      expect(policy.isHighImpact(result(group: 'lights')), isFalse);
    });
  });

  group('regression — no/unknown never execute', () {
    test('unknown text is rejected, never executed', () {
      final d = policy.decide(result(action: VoiceAction.unknown, confidence: 0));
      expect(d.decision, Decision.reject);
    });

    test('a low-confidence light is clarified, not executed', () {
      final d = policy.decide(result(device: dev('Light 1'), confidence: 0.3));
      expect(d.decision, Decision.reject);
    });
  });
}
