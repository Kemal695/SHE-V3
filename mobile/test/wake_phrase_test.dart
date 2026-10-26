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

  // ---------------------------------------------------------------------------
  // isWakeEcho — the tail of the wake phrase, as a wake session actually hears
  // it. Without this the first final of a wake session ("he's") ended the
  // session before the user's command, so multi-device commands and state
  // questions looked broken while the parser was fine.
  // ---------------------------------------------------------------------------
  group('isWakeEcho', () {
    test('treats the measured wake-word tail as an echo', () {
      // Verbatim from the LE6 log: recognizerFinal="he's".
      expect(isWakeEcho("he's"), isTrue);
      expect(isWakeEcho('hes'), isTrue);
      expect(isWakeEcho('hey'), isTrue);
      expect(isWakeEcho('robi'), isTrue);
      expect(isWakeEcho('hey robi'), isTrue);
    });

    test('treats our own "Yes?" cue as an echo', () {
      // RobiTts speaks "Yes?" as the mic opens, so the recognizer can hear it.
      expect(isWakeEcho('yes'), isTrue);
      expect(isWakeEcho('yeah'), isTrue);
      expect(isWakeEcho('okay'), isTrue);
    });

    test('treats filler and silence as an echo', () {
      expect(isWakeEcho(''), isTrue);
      expect(isWakeEcho('  '), isTrue);
      expect(isWakeEcho('uh'), isTrue);
      expect(isWakeEcho('um okay'), isTrue);
    });

    test('never treats a real command as an echo', () {
      // Three tokens is already a command — the rule only covers <= 2.
      expect(isWakeEcho('socket 2 on'), isFalse);
      expect(isWakeEcho('is socket 2 on'), isFalse);
      expect(isWakeEcho('turn on socket 1'), isFalse);
      expect(isWakeEcho('turn on socket 1 socket 2 and light 1'), isFalse);
      expect(isWakeEcho('lights on'), isFalse);
      expect(isWakeEcho('all lights on'), isFalse);
    });

    test('keeps a command that is glued to the wake tail', () {
      // The parser handles these, so the session must NOT restart on them.
      expect(isWakeEcho("he's socket 2 on"), isFalse);
      expect(isWakeEcho('hey robi turn on socket 1 and 2'), isFalse);
    });
  });
}
