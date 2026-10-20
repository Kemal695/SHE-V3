// Phase 1 — control intents (spec §6.1, §6.3).
//
// The rules that matter most here:
//   * a cancellation must never be parsed as a device action
//   * "no, the other room" is a CORRECTION, not a plain rejection
//   * a bare "no" only rejects while a confirmation is actually open

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/nlu/control_intents.dart';

void main() {
  const c = ControlIntentClassifier();

  group('cancel', () {
    test('English cancel words', () {
      for (final phrase in ['cancel', 'never mind', 'forget it', 'abort']) {
        expect(c.classify(phrase).intent, ControlIntent.cancel,
            reason: '"$phrase" should cancel');
      }
    });

    test('Amharic cancel words', () {
      expect(c.classify('ተወው').intent, ControlIntent.cancel);
      expect(c.classify('ሰርዝ').intent, ControlIntent.cancel);
    });

    test('cancel wins over an open confirmation', () {
      expect(
        c.classify('cancel',
                expecting: DialogueExpectation.confirmation)
            .intent,
        ControlIntent.cancel,
      );
    });

    test('"cancel the kitchen" is not a cancel word', () {
      // A multi-word utterance is a command, not a one-word answer.
      expect(c.classify('cancel the kitchen').intent, isNot(ControlIntent.cancel));
    });
  });

  group('stop', () {
    test('bare "stop" with nothing pending is a stop request', () {
      expect(c.classify('stop').intent, ControlIntent.stop);
    });

    test('"stop" while a confirmation is open cancels it', () {
      expect(
        c.classify('stop', expecting: DialogueExpectation.confirmation).intent,
        ControlIntent.cancel,
      );
    });
  });

  group('correction', () {
    test('"no, the other room" corrects rather than rejects', () {
      final m = c.classify('no, the other room',
          expecting: DialogueExpectation.clarification);
      expect(m.intent, ControlIntent.correctTarget);
      expect(m.correctionText, 'the other room');
    });

    test('"no, the living room" carries the new target', () {
      final m = c.classify('no, the living room',
          expecting: DialogueExpectation.confirmation);
      expect(m.intent, ControlIntent.correctTarget);
      expect(m.correctionText, 'the living room');
    });

    test('"I meant the bedroom" is a correction', () {
      final m = c.classify('I meant the bedroom');
      expect(m.intent, ControlIntent.correctTarget);
      expect(m.correctionText, 'the bedroom');
    });

    test('"change it to the garage" is a correction', () {
      final m = c.classify('change it to the garage');
      expect(m.intent, ControlIntent.correctTarget);
      expect(m.correctionText, 'the garage');
    });

    test('a bare "no" is NOT a correction (no replacement target)', () {
      expect(
        c.classify('no', expecting: DialogueExpectation.confirmation).intent,
        ControlIntent.rejectConfirmation,
      );
    });
  });

  group('yes / no', () {
    test('affirmatives confirm when a confirmation is open', () {
      for (final word in ['yes', 'yeah', 'ok', 'correct', 'that\'s right']) {
        expect(
          c.classify(word, expecting: DialogueExpectation.confirmation).intent,
          ControlIntent.confirm,
          reason: '"$word" should confirm',
        );
      }
    });

    test('Amharic affirmatives confirm', () {
      for (final word in ['አዎ', 'እሺ', 'አዎን']) {
        expect(
          c.classify(word, expecting: DialogueExpectation.confirmation).intent,
          ControlIntent.confirm,
          reason: '"$word" should confirm',
        );
      }
    });

    test('negatives reject when a confirmation is open', () {
      for (final word in ['no', 'nope', 'not that']) {
        expect(
          c.classify(word, expecting: DialogueExpectation.confirmation).intent,
          ControlIntent.rejectConfirmation,
          reason: '"$word" should reject',
        );
      }
      expect(
        c.classify('አይ', expecting: DialogueExpectation.confirmation).intent,
        ControlIntent.rejectConfirmation,
      );
    });

    test('"yes" with nothing pending is not a command', () {
      expect(c.classify('yes').intent, ControlIntent.none);
    });

    test('"no" during a clarification cancels it', () {
      expect(
        c.classify('no', expecting: DialogueExpectation.clarification).intent,
        ControlIntent.cancel,
      );
    });

    test('contradictory answer ("no, yes") is not usable', () {
      expect(
        c.classify('no yes', expecting: DialogueExpectation.confirmation).intent,
        ControlIntent.none,
      );
    });
  });

  group('undo', () {
    test('English undo', () {
      expect(c.classify('undo').intent, ControlIntent.undo);
      expect(c.classify('undo that').intent, ControlIntent.undo);
    });
  });

  group('ordinary commands are not control intents', () {
    test('device commands fall through', () {
      for (final phrase in [
        'turn on the light',
        'መብራት አብር',
        'all lights off',
      ]) {
        expect(c.classify(phrase).intent, ControlIntent.none,
            reason: '"$phrase" must reach the command parser');
      }
    });
  });
}
