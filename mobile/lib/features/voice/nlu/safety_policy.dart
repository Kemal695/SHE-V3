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

import '../voice_intent.dart';
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

  /// Risk category for an interpretation (§9).
  RiskLevel riskOf(NluResult result) {
    // A whole-class command touches many actuators at once — medium, because
    // the blast radius is larger than a single light.
    if (result.action == VoiceAction.turnAllOn ||
        result.action == VoiceAction.turnAllOff) {
      return RiskLevel.medium;
    }
    // Scenes run several actions; same reasoning.
    if (result.action == VoiceAction.activateScene) return RiskLevel.medium;
    return RiskLevel.low;
  }

  String _targetLabel(NluResult r) {
    if (r.device != null) return r.device!.label;
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
