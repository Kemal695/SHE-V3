// =============================================================================
// SHE V3 — Command safety policy
// =============================================================================
// Spec: docs/voce command.md §6 (confidence, clarification, execution rules)
// and §9 (risk categories).
//
// Turns an [NluResult] into a decision: execute, ask, or refuse. This is the
// only place thresholds live, so calibration from the corpus changes numbers
// here and nowhere else.
//
// IMPORTANT — what "risk" can be today:
//   The firmware exposes exactly one writable parameter, `Power` (bool)
//   (firmware/v3/main/device_profiles.c). There is no gate, no irrigation and
//   no brightness, so every command the product can currently execute is LOW
//   risk. [RiskLevel.high] exists so that adding a gate later cannot silently
//   inherit today's "just execute it" behaviour.
// =============================================================================

import 'voice_command.dart';
import 'command_nlu.dart';

enum Decision {
  /// Confident and unambiguous — send it.
  execute,

  /// Ask a question instead of guessing.
  clarify,

  /// Do not act; tell the user Robi did not understand.
  reject,
}

enum RiskLevel { low, medium, high }

class PolicyDecision {
  final Decision decision;
  final RiskLevel risk;

  /// Why this decision was reached — surfaced in logs and, for [Decision.reject],
  /// as the message to the user.
  final String reason;

  /// The question to ask for [Decision.clarify].
  final String? question;

  const PolicyDecision({
    required this.decision,
    required this.risk,
    required this.reason,
    this.question,
  });
}

class CommandSafetyPolicy {
  const CommandSafetyPolicy({
    this.autoExecute = 0.80,
    this.clarifyFloor = 0.55,
  });

  /// At or above this, an unambiguous command is executed.
  ///
  /// 0.80, not 0.85: measured on the device, a device-targeted command
  /// ("turn on bedroom light") scores **0.82** from the parser — a full
  /// device-name match with a known verb. At 0.85 that meant EVERY device
  /// command was answered with a clarification question instead of being
  /// carried out, which reads as "the command does nothing". A group command
  /// scores 0.85, so only group commands ever executed.
  ///
  /// This is safe because a wrong target is caught by the ambiguity check
  /// above, independently of confidence.
  final double autoExecute;

  /// At or above this (but below [autoExecute]) Robi asks for confirmation
  /// rather than executing.
  final double clarifyFloor;

  /// Actions that always need a confirmation step, whatever the language
  /// confidence says. Empty today because no such actuator exists yet.
  static const Set<VoiceAction> _alwaysConfirm = {};

  /// Device / actuator keywords that always require an explicit confirmation
  /// step (Plan §D.10 / §4.1). A wrong TARGET here is physically consequential
  /// (a gate left open, a door unlocked), not just a wrong light, so these must
  /// be confirmed even at full confidence. The firmware's `Power`-only world
  /// does not yet contain them, but the hook is here so adding a gate later
  /// cannot silently inherit today's "just execute it" behaviour.
  ///
  /// Matched as whole-name tokens so "gate" does not fire on an unrelated word.
  static const Set<String> highImpactDeviceKeywords = {
    'gate', 'entrance', 'door', 'garage', 'unlock', 'lock',
    'በር', // door / gate
    'ማዕበር', // gate
  };

  PolicyDecision decide(NluResult result) {
    final risk = riskOf(result);

    // ---- Nothing understood ----------------------------------------------
    if (result.isUnknown) {
      return PolicyDecision(
        decision: Decision.reject,
        risk: risk,
        reason: "I heard \"${result.transcript}\" but didn't understand it.",
      );
    }

    // ---- A question changes nothing ---------------------------------------
    // Asking "is the gate open?" must never trigger a confirmation, and must
    // never be re-opened as "which one?" — it is answered as asked.
    if (result.action == VoiceAction.queryState) {
      return PolicyDecision(
        decision: Decision.execute,
        risk: risk,
        reason: 'state question',
      );
    }

    // ---- Locked custom command ------------------------------------------
    // The user marked this command "locked": always confirm before running,
    // even at full confidence. That is the point of the lock.
    if (result.locked) {
      return PolicyDecision(
        decision: Decision.clarify,
        risk: risk,
        reason: 'locked command requires confirmation',
        question: 'This command is locked. Do you want to run it?',
      );
    }

    // ---- Ambiguous target ------------------------------------------------
    // Never pick silently. Two devices scoring within the window means the
    // transcript does not distinguish them, and a guess is a wrong device.
    if (result.isAmbiguous) {
      return PolicyDecision(
        decision: Decision.clarify,
        risk: risk,
        reason: 'ambiguous device',
        question: 'Which one — ${result.candidateLabels}?',
      );
    }

    // ---- High-risk: always confirm ---------------------------------------
    if (_alwaysConfirm.contains(result.action) || risk == RiskLevel.high) {
      return PolicyDecision(
        decision: Decision.clarify,
        risk: risk,
        reason: 'high-risk action requires confirmation',
        question: 'Do you want me to do that?',
      );
    }

    // ---- Confidence bands ------------------------------------------------
    if (result.confidence >= autoExecute) {
      return PolicyDecision(
        decision: Decision.execute,
        risk: risk,
        reason: 'confident (${result.confidence.toStringAsFixed(2)})',
      );
    }

    if (result.confidence >= clarifyFloor) {
      return PolicyDecision(
        decision: Decision.clarify,
        risk: risk,
        reason: 'low confidence (${result.confidence.toStringAsFixed(2)})',
        question: 'Did you mean ${_targetLabel(result)}?',
      );
    }

    return PolicyDecision(
      decision: Decision.reject,
      risk: risk,
      reason: "I didn't understand that clearly. Please say it again.",
    );
  }

  /// True when the interpretation targets a high-impact actuator (a gate, an
  /// entrance, a lock). These must always be confirmed because a wrong target is
  /// physically consequential, not just an inconvenience, and the firmware's
  /// `Power`-only world does not yet contain them — this hook is what stops a
  /// future gate from inheriting today's "just execute it" behaviour.
  bool isHighImpact(NluResult result) {
    final name = (result.device?.deviceName ??
            result.deviceGroup?.name ??
            result.automation?.name ??
            '')
        .toLowerCase();
    final group = (result.group ?? '').toLowerCase();
    final tokens = {
      ...name.split(RegExp(r'\s+')),
      ...group.split(RegExp(r'\s+')),
    };
    return tokens.any((t) => highImpactDeviceKeywords.contains(t));
  }

  /// Risk category for an interpretation (§9).
  RiskLevel riskOf(NluResult result) {
    // A high-impact target (gate / entrance / lock) is always high risk, even
    // at full confidence — it must be confirmed, never auto-executed.
    if (isHighImpact(result)) return RiskLevel.high;

    // A whole-class command touches many actuators at once — medium, because
    // the blast radius is larger than a single light.
    if (result.action == VoiceAction.turnAllOn ||
        result.action == VoiceAction.turnAllOff) {
      return RiskLevel.medium;
    }
    // Scenes run several actions; same reasoning.
    if (result.action == VoiceAction.activateScene) return RiskLevel.medium;
    // A user-defined group touches several actuators, and an automation runs a
    // whole rule — both have a wider blast radius than one light.
    if (result.action == VoiceAction.turnOnGroup ||
        result.action == VoiceAction.turnOffGroup ||
        result.action == VoiceAction.runAutomation ||
        result.action == VoiceAction.enableAutomation ||
        result.action == VoiceAction.disableAutomation) {
      return RiskLevel.medium;
    }
    return RiskLevel.low;
  }

  String _targetLabel(NluResult r) {
    // A multi-device command must name every target in the confirmation, or the
    // prompt under-reports what will actually happen.
    if (r.devices.isNotEmpty) {
      return r.devices.map((d) => d.label).join(', ');
    }
    if (r.deviceGroup != null) return r.deviceGroup!.name;
    if (r.automation != null) return r.automation!.name;
    if (r.group != null) {
      return switch (r.group) {
        'lights' => 'all the lights',
        'sockets' => 'all the sockets',
        _ => 'all the devices',
      };
    }
    return 'that';
  }
}

const commandSafetyPolicy = CommandSafetyPolicy();
