import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/core/voice/wake_phrase.dart';

void main() {
  group('isWakePhrase', () {
    test('accepts the phrase however the recogniser spells the name', () {
      // "Robi" is not a word, so these are all normal transcriptions of the
      // same utterance — measured on the device.
      expect(isWakePhrase('hey robi'), isTrue);
      expect(isWakePhrase('Hey Roby'), isTrue);
      expect(isWakePhrase('hey robby'), isTrue);
      expect(isWakePhrase('hey robie,'), isTrue);
      expect(isWakePhrase('hey, robi'), isTrue);
    });

    test('accepts the phrase inside a longer command (barge-in)', () {
      expect(isWakePhrase('hey robi turn on the light'), isTrue);
      expect(isWakePhrase('okay hey roby stop'), isTrue);
    });

    test('rejects "hey" alone', () {
      // Would fire on ordinary conversation.
      expect(isWakePhrase('hey'), isFalse);
      expect(isWakePhrase('hey there'), isFalse);
    });

    test('rejects "robi" without "hey"', () {
      expect(isWakePhrase('robi'), isFalse);
      expect(isWakePhrase('turn on robert light'), isFalse);
    });

    test('rejects ordinary commands', () {
      expect(isWakePhrase('turn on bedroom light'), isFalse);
      expect(isWakePhrase('turn off all sockets'), isFalse);
      expect(isWakePhrase(''), isFalse);
    });
  });
}
