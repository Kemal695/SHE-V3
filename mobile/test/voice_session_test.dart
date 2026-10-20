// Phase 1 — voice session state machine (spec §6.2).
//
// Timeouts are driven by an injected clock, so these run instantly and prove the
// retry limits rather than trusting them.

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/nlu/control_intents.dart';
import 'package:she_mobile/features/voice/nlu/voice_session.dart';

void main() {
  late DateTime now;

  setUp(() => now = DateTime(2026, 1, 1, 12, 0, 0));

  VoiceSession session([String id = 'tx-1']) =>
      VoiceSession(transactionId: id, clock: () => now);

  group('happy path', () {
    test('begin → speech → transcript', () {
      final s = session();
      expect(s.begin(), SessionStep.waiting);
      expect(s.state, SessionState.listeningForCommand);

      expect(s.onSpeechDetected(), SessionStep.waiting);
      expect(s.state, SessionState.interpreting);

      expect(s.onTranscript(), SessionStep.interpret);
    });

    test('confirmation → execute → done', () {
      final s = session();
      s.begin();
      s.onSpeechDetected();
      s.onTranscript();
      expect(s.askConfirmation('Do you mean the bedroom light?'),
          SessionStep.askConfirmation);
      expect(s.state, SessionState.awaitingYesNoConfirmation);
      expect(s.expectation, DialogueExpectation.confirmation);

      expect(
        s.onControl(const ControlMatch(ControlIntent.confirm),
            transactionId: 'tx-1'),
        SessionStep.execute,
      );
      expect(s.state, SessionState.submitting);

      s.onSubmit();
      expect(s.state, SessionState.awaitingDeviceResult);
      expect(s.onDeviceResult(ok: true), SessionStep.done);
      expect(s.state, SessionState.completed);
    });
  });

  group('silence before the command', () {
    test('8 s of silence ends the transaction', () {
      final s = session();
      s.begin();

      now = now.add(const Duration(seconds: 7));
      expect(s.tick(), SessionStep.waiting);

      now = now.add(const Duration(seconds: 2));
      expect(s.tick(), SessionStep.cancelled);
      expect(s.state, SessionState.timedOut);
    });
  });

  group('clarification retry limits', () {
    test('one re-prompt is allowed, then the session is cancelled', () {
      final s = session();
      s.begin();
      s.onSpeechDetected();
      s.onTranscript();
      s.askClarification(ClarifyField.device, 'Which one?');

      // First wait expires → re-prompt.
      now = now.add(const Duration(seconds: 11));
      expect(s.tick(), SessionStep.askAgain);
      expect(s.state, SessionState.awaitingDeviceClarification);

      // Second wait expires → cancel (max 2 attempts per field).
      now = now.add(const Duration(seconds: 11));
      expect(s.tick(), SessionStep.cancelled);
      expect(s.state, SessionState.timedOut);
    });

    test('a third explicit clarification on one field cancels', () {
      final s = session();
      s.begin();
      s.onTranscript();

      expect(s.askClarification(ClarifyField.device, 'Which one?'),
          SessionStep.askClarification);
      expect(s.askClarification(ClarifyField.device, 'Which one?'),
          SessionStep.askClarification);
      expect(s.askClarification(ClarifyField.device, 'Which one?'),
          SessionStep.cancelled);
      expect(s.state, SessionState.cancelled);
    });

    test('a transaction is capped at 3 clarification turns in total', () {
      final s = session();
      s.begin();
      s.onTranscript();

      s.askClarification(ClarifyField.room, 'Which room?');
      s.askClarification(ClarifyField.device, 'Which device?');
      s.askClarification(ClarifyField.action, 'On or off?');
      expect(s.clarificationTurns, 3);

      expect(s.askClarification(ClarifyField.room, 'Which room?'),
          SessionStep.cancelled);
    });
  });

  group('stale replies', () {
    test('a reply from another transaction is ignored', () {
      final s = session('tx-new');
      s.begin();
      s.onTranscript();
      s.askConfirmation('Do you want me to do that?');

      expect(
        s.onControl(const ControlMatch(ControlIntent.confirm),
            transactionId: 'tx-old'),
        SessionStep.waiting,
      );
      // Still waiting — the stale "yes" did not authorise anything.
      expect(s.state, SessionState.awaitingYesNoConfirmation);
    });

    test('isStale compares ids', () {
      final s = session('tx-new');
      expect(s.isStale('tx-old'), isTrue);
      expect(s.isStale('tx-new'), isFalse);
    });
  });

  group('control intents inside a session', () {
    test('reject cancels instead of executing', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askConfirmation('Do you want me to do that?');

      expect(
        s.onControl(const ControlMatch(ControlIntent.rejectConfirmation),
            transactionId: 'tx-1'),
        SessionStep.cancelled,
      );
      expect(s.state, SessionState.cancelled);
    });

    test('"yes" during a clarification is not a confirmation', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askClarification(ClarifyField.room, 'Which room?');

      expect(
        s.onControl(const ControlMatch(ControlIntent.confirm),
            transactionId: 'tx-1'),
        SessionStep.notUnderstood,
      );
      expect(s.state, SessionState.awaitingRoomClarification);
    });

    test('a correction re-interprets and clears the deadline', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askClarification(ClarifyField.room, 'Which room?');

      expect(
        s.onControl(
            const ControlMatch(ControlIntent.correctTarget,
                correctionText: 'the other room'),
            transactionId: 'tx-1'),
        SessionStep.interpret,
      );
      expect(s.state, SessionState.interpreting);
      expect(s.awaitingAnswer, isFalse);
    });

    test('cancel during a clarification ends it', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askClarification(ClarifyField.device, 'Which one?');

      expect(
        s.onControl(const ControlMatch(ControlIntent.cancel),
            transactionId: 'tx-1'),
        SessionStep.cancelled,
      );
      expect(s.isOpen, isFalse);
    });

    test('an ordinary answer to a clarification is interpreted', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askClarification(ClarifyField.room, 'Which room?');

      expect(
        s.onControl(ControlMatch.none, transactionId: 'tx-1'),
        SessionStep.interpret,
      );
    });
  });

  group('device result', () {
    test('a timeout after submitting is reported as a failure, not success', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askConfirmation('Sure?');
      s.onControl(const ControlMatch(ControlIntent.confirm),
          transactionId: 'tx-1');
      s.onSubmit();

      now = now.add(const Duration(seconds: 11));
      expect(s.tick(), SessionStep.failed);
      expect(s.state, SessionState.timedOut);
    });

    test('a failed device result marks the session failed', () {
      final s = session();
      s.begin();
      s.onTranscript();
      s.askConfirmation('Sure?');
      s.onControl(const ControlMatch(ControlIntent.confirm),
          transactionId: 'tx-1');
      s.onSubmit();

      expect(s.onDeviceResult(ok: false), SessionStep.failed);
      expect(s.state, SessionState.failed);
    });
  });
}
