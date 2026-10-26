// =============================================================================
// SHE V3 — Shared command brain (Plan §4 unified pipeline)
// =============================================================================
// Both entry points (the manual FAB / voice screen and the native wake word)
// call [HandleUtterance.handleUtterance]. It is the single place that decides
// whether to execute, and it keeps one clarification/confirmation dialogue open
// across utterances (the spec's "shared command brain").
//
// Order (Plan §4): control intents -> normalize (in the NLU) -> parse ->
// resolve -> safety policy -> execute (via CommandExecutor).
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/voice_diagnostics.dart';
import '../data/amharic_normalizer.dart';
import '../domain/command_nlu.dart';
import '../domain/command_safety_policy.dart';
import '../domain/control_intents.dart';
import '../domain/voice_command.dart';
import '../domain/command_result.dart';
import 'voice_session.dart';
import 'command_executor.dart';

class HandleUtterance {
  final Ref ref;
  final CommandExecutor executor;

  HandleUtterance(this.ref, this.executor);

  /// Dialogue state. A pending confirmation is tied to the stored transcript
  /// (re-read at execution time, so a rename cannot send a command to the
  /// wrong channel) and to a transaction id owned by [_session].
  VoiceSession? _session;
  String? _pendingTranscript;

  void _expireIfStale() {
    final s = _session;
    if (s == null) return;
    s.tick();
    if (!s.isOpen) _clearDialogue();
  }

  void _clearDialogue() {
    _session = null;
    _pendingTranscript = null;
  }

  VoiceIntent _toIntent(NluResult r) => VoiceIntent(
        action: r.action,
        devices: r.devices,
        group: r.group,
        sceneId: r.sceneId,
        deviceGroup: r.deviceGroup,
        automation: r.automation,
        locked: r.locked,
        fromCustom: r.fromCustom,
        level: r.level,
        confidence: r.confidence,
      );

  /// Interpret [transcript], decide whether it is safe to run, and either run
  /// it or ask a question. Returns the same shape the UI already consumes.
  Future<({VoiceIntent intent, String message})> handleUtterance(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
    required bool amharic,
  }) async {
    _expireIfStale();

    debugPrint('Voice: heard "${transcript.replaceAll("\n", " ")}" '
        '(amharic=$amharic, latinTokens=$latinDeviceTokens)');
    VoiceLog.log('heard="$transcript" amharic=$amharic '
        'latinTokens=$latinDeviceTokens');

    final speaksEthiopic = transcript.trim().isNotEmpty &&
        amharicNormalizer.containsEthiopic(transcript);
    // The am-ET recognizer frequently injects stray Ethiopic characters
    // (punctuation like ።, or transliterated fragments) into an English
    // utterance. The previous `effectiveLatin = latinDeviceTokens ||
    // !speaksEthiopic` therefore flipped to FALSE the moment any Ethiopic crept
    // in, which disabled English question-word / verb / device-token detection —
    // so "is soket 2 on" (which the device matcher DOES resolve to Socket 2)
    // fell through to `unknown`. Re-enable Latin parsing whenever the transcript
    // still contains Latin letters, so a mixed/English utterance is never
    // silently downgraded to Amharic-only parsing. Amharic verbs/words are still
    // detected via the `amharic` flag, so this does not weaken genuine Amharic.
    final hasLatin = transcript.trim().isNotEmpty &&
        amharicNormalizer.containsLatin(transcript);
    final effectiveLatin =
        latinDeviceTokens || !speaksEthiopic || hasLatin;

    // ---- 1. Is this a reply to an open question? -------------------------
    final session = _session;
    final pending = _pendingTranscript;
    if (session != null && pending != null && session.isOpen) {
      final match = controlIntentClassifier.classify(
        transcript,
        expecting: session.expectation,
      );
      final step = session.onControl(
        match,
        transactionId: session.transactionId,
      );

      switch (step) {
        case SessionStep.cancelled:
          _clearDialogue();
          return (
            intent: const VoiceIntent.unknown(),
            message: 'Cancelled — nothing was changed.',
          );

        case SessionStep.execute:
          _clearDialogue();
          final execT0 = DateTime.now();
          final result = await executor.executeTranscript(
            pending,
            homeId: homeId,
            latinDeviceTokens: effectiveLatin,
            amharic: amharic,
          );
          VoiceDiagnostics.traceStage(
            'execute',
            durationMs: DateTime.now().difference(execT0).inMilliseconds,
          );
          return (intent: result.intent, message: result.message);

        case SessionStep.notUnderstood:
          return (
            intent: const VoiceIntent.unknown(),
            message: session.currentQuestion ?? 'Sorry, can you say that again?',
          );

        case SessionStep.interpret:
          final text = match.correctionText ?? transcript;
          return _decideAndAct(
            text,
            homeId: homeId,
            latinDeviceTokens: effectiveLatin,
            amharic: amharic,
          );

        default:
          break;
      }
    }

    // ---- 2. A fresh command ----------------------------------------------
    return _decideAndAct(
      transcript,
      homeId: homeId,
      latinDeviceTokens: effectiveLatin,
      amharic: amharic,
    );
  }

  /// Choose the hypothesis that parses best out of everything the recognizer
  /// offered for one utterance.
  ///
  /// The top hypothesis is often mangled while a lower-ranked one is usable —
  /// measured on the LE6:
  ///
  ///   alternates=["turn on second one socket sock",
  ///               "turn on socket one socket to sock", …]
  ///
  /// Only the second yields a device list. Ranking: a known parse always beats
  /// an unknown one, then confidence decides, with explicit device targets
  /// preferred over a blanket group action ("socket 1 and 2" over "all sockets").
  Future<String> bestHypothesis(
    List<String> hypotheses, {
    required String homeId,
    required bool latinDeviceTokens,
    required bool amharic,
  }) async {
    if (hypotheses.length <= 1) {
      return hypotheses.isEmpty ? '' : hypotheses.first;
    }
    final ctx = await executor.loadContext(homeId);
    var best = hypotheses.first;
    var bestScore = -1.0;
    for (final h in hypotheses) {
      if (h.trim().isEmpty) continue;
      // Same Latin-eligibility rule as the entry point below: a transcript that
      // still contains Latin letters must be parsed with Latin tokens, even in
      // Amharic mode, so the am-ET model's stray Ethiopic does not downgrade it
      // to unknown. Without this, the alternates of an English query in Amharic
      // mode all score 0 and the recognizer's top guess (often garbled) wins.
      final hSpeaksEthiopic =
          h.trim().isNotEmpty && amharicNormalizer.containsEthiopic(h);
      final hHasLatin =
          h.trim().isNotEmpty && amharicNormalizer.containsLatin(h);
      final hLatin = latinDeviceTokens || !hSpeaksEthiopic || hHasLatin;
      final r = commandNlu.interpret(
        h,
        devices: ctx.devices,
        scenes: ctx.scenes,
        groups: ctx.groups,
        automations: ctx.automations,
        customCommands: ctx.customCommands,
        latinDeviceTokens: hLatin,
        amharic: amharic,
      );
      var score = r.action == VoiceAction.unknown ? 0.0 : r.confidence;
      if (r.action != VoiceAction.unknown) {
        // A named target beats a blanket group action, and a longer target list
        // is more specific than a shorter one — measured against the real
        // alternates of "turn on socket 1 socket 2 and light 1":
        //   "turn on second one socket sock"     -> all sockets   (0.80)
        //   "turn on socket one socket sock"     -> Socket 1      (0.83)
        //   "turn on socket one socket to sock"  -> Socket 1 + 2  (0.84)  <- wins
        score += 0.01 * r.devices.length;
        if (r.action == VoiceAction.turnAllOn ||
            r.action == VoiceAction.turnAllOff) {
          score -= 0.05;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = h;
      }
    }
    if (best != hypotheses.first) {
      VoiceLog.log(
          'best hypothesis="$best" chosen over "${hypotheses.first}"');
    }
    return best;
  }

  Future<({VoiceIntent intent, String message})> _decideAndAct(
    String transcript, {
    required String homeId,
    required bool latinDeviceTokens,
    required bool amharic,
  }) async {
    final ctx = await executor.loadContext(homeId);
    final t0 = DateTime.now();
    final result = commandNlu.interpret(
      transcript,
      devices: ctx.devices,
      scenes: ctx.scenes,
      groups: ctx.groups,
      automations: ctx.automations,
      customCommands: ctx.customCommands,
      latinDeviceTokens: latinDeviceTokens,
      amharic: amharic,
    );
    VoiceDiagnostics.traceStage(
      'parse',
      durationMs: DateTime.now().difference(t0).inMilliseconds,
    );
    final decision = commandSafetyPolicy.decide(result);

    // Log EVERY target, not just the first: a multi-device command that only
    // acted on some of them is indistinguishable from a parse that only found
    // one, and the log is the only place that difference is visible.
    final targets =
        result.devices.map((d) => d.label).join(' + ');
    VoiceLog.log('heard="$transcript" lang=${result.language} '
        'action=${result.action} '
        'devices=[${targets.isEmpty ? '-' : targets}] '
        'group=${result.group} scene=${result.sceneId != null} '
        'confidence=${result.confidence.toStringAsFixed(2)} '
        'ambiguous=${result.isAmbiguous} '
        'decision=${decision.decision} reason="${decision.reason}"');

    switch (decision.decision) {
      case Decision.execute:
        _clearDialogue();
        final execT0 = DateTime.now();
        final cmd = await executor.executeTranscript(
          transcript,
          homeId: homeId,
          latinDeviceTokens: latinDeviceTokens,
          amharic: amharic,
        );
        VoiceDiagnostics.traceStage(
          'execute',
          durationMs: DateTime.now().difference(execT0).inMilliseconds,
        );
        return (intent: cmd.intent, message: cmd.message);

      case Decision.clarify:
        final session = VoiceSession(
          transactionId: 'tx-${DateTime.now().microsecondsSinceEpoch}',
        );
        session.begin();
        if (result.isAmbiguous) {
          session.askClarification(
            ClarifyField.device,
            decision.question ?? 'Which one?',
          );
        } else {
          session.askConfirmation(
            decision.question ?? 'Did you mean that?',
          );
        }
        _session = session;
        _pendingTranscript = transcript;
        return (
          intent: _toIntent(result),
          message: decision.question ?? 'Did you mean that?',
        );

      case Decision.reject:
        _clearDialogue();
        return (intent: _toIntent(result), message: decision.reason);
    }
  }
}
