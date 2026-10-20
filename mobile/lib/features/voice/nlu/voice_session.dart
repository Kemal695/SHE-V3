// =============================================================================
// SHE V3 — Voice session state machine
// =============================================================================
// Spec: docs/voce command.md §6.2 (explicit states, timeouts, retry limits,
// transaction expiry) and §6.1 (control intents must be processed first).
//
// WHY A STATE MACHINE AND NOT A SERIES OF PROMPTS
// An informal "ask again if unsure" loop has no memory: it cannot enforce a
// retry limit, it cannot expire, and — the dangerous one — a "yes" answered to a
// stale prompt can authorise a newer command. Every session therefore carries a
// transaction id, and a reply from a different transaction is rejected.
//
// This class is pure: no timers, no plugins, no I/O. The caller drives the clock
// (see [now] / [tick]) so timeout behaviour is unit-testable without waiting.
// =============================================================================

import 'control_intents.dart';

/// The states from §6.2, in the same vocabulary.
enum SessionState {
  idle,
  listeningForCommand,
  interpreting,
  awaitingRoomClarification,
  awaitingDeviceClarification,
  awaitingActionClarification,
  awaitingYesNoConfirmation,
  submitting,
  awaitingDeviceResult,
  completed,
  cancelled,
  timedOut,
  failed,
}

/// What the coordinator should do next after handing an event to the session.
enum SessionStep {
  /// Nothing to do yet (still listening, still waiting).
  waiting,

  /// Run the command engine on the transcript.
  interpret,

  /// Re-ask the same question (one re-prompt allowed).
  askAgain,

  /// Ask the user to choose between candidates.
  askClarification,

  /// Ask a yes/no question before executing.
  askConfirmation,

  /// Send the command.
  execute,

  /// End the transaction without executing.
  cancelled,

  /// The user's answer was not usable — say so, keep the transaction open.
  notUnderstood,

  /// Finished successfully.
  done,

  /// Finished with a failure.
  failed,
}

/// Which field a clarification is about. Used for the per-field retry limit.
enum ClarifyField { room, device, action }

class SessionConfig {
  const SessionConfig({
    this.silenceBeforeCommand = const Duration(seconds: 8),
    this.maxUtterance = const Duration(seconds: 12),
    this.promptWait = const Duration(seconds: 10),
    this.maxAttemptsPerField = 2,
    this.maxClarificationTurns = 3,
  });

  /// §6.2: up to 8 s of silence after activation before the session ends.
  final Duration silenceBeforeCommand;

  /// §6.2: a 12 s maximum utterance window.
  final Duration maxUtterance;

  /// §6.2: each clarification/yes-no prompt waits 10 s.
  final Duration promptWait;

  /// §6.2: no more than 2 attempts per unresolved field (prompt + one re-prompt).
  final int maxAttemptsPerField;

  /// §6.2: a transaction is limited to 3 clarification turns in total.
  final int maxClarificationTurns;
}

class VoiceSession {
  VoiceSession({
    required this.transactionId,
    this.config = const SessionConfig(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Unique per activation. A reply carrying a different id is stale.
  final String transactionId;
  final SessionConfig config;
  final DateTime Function() _clock;

  SessionState _state = SessionState.idle;
  SessionState get state => _state;

  DateTime? _deadline;

  /// When the current wait expires, or null if no wait is active.
  DateTime? get deadline => _deadline;

  int _clarificationTurns = 0;
  int get clarificationTurns => _clarificationTurns;

  final Map<ClarifyField, int> _attempts = {};
  ClarifyField? _currentField;

  /// The question currently on screen/speaker, so a re-prompt repeats it
  /// verbatim instead of inventing a new one.
  String? currentQuestion;

  bool get isOpen => switch (_state) {
        SessionState.idle ||
        SessionState.completed ||
        SessionState.cancelled ||
        SessionState.timedOut ||
        SessionState.failed =>
          false,
        _ => true,
      };

  bool get awaitingAnswer =>
      _state == SessionState.awaitingRoomClarification ||
      _state == SessionState.awaitingDeviceClarification ||
      _state == SessionState.awaitingActionClarification ||
      _state == SessionState.awaitingYesNoConfirmation;

  /// §6.3: what the user's next utterance should be interpreted as.
  DialogueExpectation get expectation => switch (_state) {
        SessionState.awaitingYesNoConfirmation =>
          DialogueExpectation.confirmation,
        SessionState.awaitingRoomClarification ||
        SessionState.awaitingDeviceClarification ||
        SessionState.awaitingActionClarification =>
          DialogueExpectation.clarification,
        _ => DialogueExpectation.none,
      };

  // ---- Lifecycle ---------------------------------------------------------

  /// Start a transaction: wait up to [SessionConfig.silenceBeforeCommand] for the
  /// user to begin speaking.
  SessionStep begin() {
    _state = SessionState.listeningForCommand;
    _deadline = _clock().add(config.silenceBeforeCommand);
    _clarificationTurns = 0;
    _attempts.clear();
    _currentField = null;
    currentQuestion = null;
    return SessionStep.waiting;
  }

  /// Speech was detected — switch from "waiting for the user to start" to
  /// "waiting for the sentence to finish".
  SessionStep onSpeechDetected() {
    if (_state != SessionState.listeningForCommand) return SessionStep.waiting;
    _state = SessionState.interpreting;
    _deadline = _clock().add(config.maxUtterance);
    return SessionStep.waiting;
  }

  /// A final transcript arrived. The command engine runs next.
  SessionStep onTranscript() {
    if (!isOpen) return SessionStep.waiting;
    _state = SessionState.interpreting;
    // The utterance window is cleared: interpretation is local and fast, and
    // leaving a deadline here would time out a command that was already heard.
    _deadline = null;
    return SessionStep.interpret;
  }

  // ---- Questions ---------------------------------------------------------

  /// Ask which room/device/action was meant.
  ///
  /// Returns [SessionStep.cancelled] when the transaction has used up its
  /// clarification budget — the spec is explicit that Robi must not loop.
  SessionStep askClarification(ClarifyField field, String question) {
    if (!isOpen) return SessionStep.cancelled;

    final attempts = (_attempts[field] ?? 0) + 1;
    if (attempts > config.maxAttemptsPerField) {
      _cancel();
      return SessionStep.cancelled;
    }
    if (_clarificationTurns >= config.maxClarificationTurns) {
      _cancel();
      return SessionStep.cancelled;
    }

    _attempts[field] = attempts;
    _currentField = field;
    _clarificationTurns++;
    currentQuestion = question;
    _state = switch (field) {
      ClarifyField.room => SessionState.awaitingRoomClarification,
      ClarifyField.device => SessionState.awaitingDeviceClarification,
      ClarifyField.action => SessionState.awaitingActionClarification,
    };
    _deadline = _clock().add(config.promptWait);
    return SessionStep.askClarification;
  }

  /// Ask a yes/no question before executing.
  SessionStep askConfirmation(String question) {
    if (!isOpen) return SessionStep.cancelled;
    currentQuestion = question;
    _state = SessionState.awaitingYesNoConfirmation;
    _deadline = _clock().add(config.promptWait);
    return SessionStep.askConfirmation;
  }

  // ---- Answers -----------------------------------------------------------

  /// Feed a control-intent match into the session.
  ///
  /// [transactionId] must match; a stale "yes" from a previous prompt returns
  /// [SessionStep.waiting] and changes nothing (§6.3, §6.2).
  SessionStep onControl(ControlMatch match, {required String transactionId}) {
    if (isStale(transactionId)) return SessionStep.waiting;
    if (!isOpen) return SessionStep.waiting;

    switch (match.intent) {
      case ControlIntent.cancel:
        _cancel();
        return SessionStep.cancelled;

      case ControlIntent.rejectConfirmation:
        // Rejecting is a cancellation, never permission to execute.
        _cancel();
        return SessionStep.cancelled;

      case ControlIntent.confirm:
        // A confirmation only authorises the pending action while a yes/no
        // prompt is actually open. A "yes" during a clarification is not an
        // answer to "which room?".
        if (_state != SessionState.awaitingYesNoConfirmation) {
          return SessionStep.notUnderstood;
        }
        _deadline = null;
        _state = SessionState.submitting;
        return SessionStep.execute;

      case ControlIntent.correctTarget:
        // Replace the target and re-resolve; the previous target must not be
        // executed. The correction is treated as a new clarification answer.
        _deadline = _clock().add(config.maxUtterance);
        _state = SessionState.interpreting;
        return SessionStep.interpret;

      case ControlIntent.stop:
        // Only meaningful with a running actuator; the coordinator decides.
        return SessionStep.waiting;

      case ControlIntent.undo:
        return SessionStep.waiting;

      case ControlIntent.none:
        // A real answer to a clarification question — the transcript is the
        // new value (e.g. "the living room").
        if (awaitingAnswer) {
          _deadline = null;
          _state = SessionState.interpreting;
          return SessionStep.interpret;
        }
        return SessionStep.waiting;
    }
  }

  /// A transcript arrived while a prompt was open but it was not usable.
  ///
  /// §6.2: the timeout is reset only for a VALID response, so this deliberately
  /// leaves the existing deadline alone.
  SessionStep onUnusableAnswer() {
    if (!awaitingAnswer) return SessionStep.waiting;
    return SessionStep.notUnderstood;
  }

  // ---- Execution ---------------------------------------------------------

  SessionStep onSubmit() {
    if (_state != SessionState.submitting) return SessionStep.waiting;
    _state = SessionState.awaitingDeviceResult;
    _deadline = _clock().add(config.promptWait);
    return SessionStep.waiting;
  }

  SessionStep onDeviceResult({required bool ok}) {
    _deadline = null;
    _state = ok ? SessionState.completed : SessionState.failed;
    return ok ? SessionStep.done : SessionStep.failed;
  }

  SessionStep cancel() {
    if (!isOpen) return SessionStep.waiting;
    _cancel();
    return SessionStep.cancelled;
  }

  // ---- Time --------------------------------------------------------------

  /// Advance the clock. Returns [SessionStep.cancelled] when a wait expired for
  /// good, [SessionStep.askAgain] when one re-prompt is still allowed, and
  /// [SessionStep.waiting] while the deadline is in the future.
  SessionStep tick() {
    final due = _deadline;
    if (due == null || !isOpen) return SessionStep.waiting;
    if (_clock().isBefore(due)) return SessionStep.waiting;
    return onTimeout();
  }

  /// Handle an expired deadline explicitly (also used by tests).
  SessionStep onTimeout() {
    if (!isOpen) return SessionStep.waiting;

    // Never heard anything after activation — nothing to cancel.
    if (_state == SessionState.listeningForCommand) {
      _deadline = null;
      _state = SessionState.timedOut;
      return SessionStep.cancelled;
    }

    // Waiting on the user. §6.2: repeat the prompt ONCE, then cancel.
    if (awaitingAnswer) {
      final field = _currentField ?? ClarifyField.action;
      final attempts = (_attempts[field] ?? 0) + 1;
      if (attempts <= config.maxAttemptsPerField &&
          _clarificationTurns <= config.maxClarificationTurns) {
        _attempts[field] = attempts;
        _clarificationTurns++;
        _deadline = _clock().add(config.promptWait);
        return SessionStep.askAgain;
      }
      _deadline = null;
      _state = SessionState.timedOut;
      return SessionStep.cancelled;
    }

    // Already sent to the device: we cannot claim it failed, and we must not
    // claim it succeeded. Report the timeout honestly.
    if (_state == SessionState.awaitingDeviceResult ||
        _state == SessionState.submitting) {
      _deadline = null;
      _state = SessionState.timedOut;
      return SessionStep.failed;
    }

    _deadline = null;
    _state = SessionState.timedOut;
    return SessionStep.cancelled;
  }

  /// §6.2: a new wake phrase starts a NEW transaction; nothing is inherited.
  bool isStale(String otherTransactionId) => otherTransactionId != transactionId;

  void _cancel() {
    _state = SessionState.cancelled;
    _deadline = null;
    currentQuestion = null;
  }
}
