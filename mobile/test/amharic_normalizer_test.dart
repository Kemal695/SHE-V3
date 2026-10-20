// Phase 1 — Amharic + language-neutral normalization (spec §5.3).

import 'package:flutter_test/flutter_test.dart';
import 'package:she_mobile/features/voice/nlu/amharic_normalizer.dart';

void main() {
  const n = AmharicTextNormalizer();

  group('normalize', () {
    test('lowercases and trims Latin text', () {
      expect(n.normalize('  Turn ON the Light 1.  '), 'turn on the light 1');
    });

    test('strips Ethiopic punctuation but keeps the words', () {
      // ። (U+1362) is a full stop; the word itself must survive.
      expect(n.normalize('መብራት።'), 'መብራት');
      expect(n.normalize('የመኝታ ቤቱን መብራት አብራ።'), 'የመኝታ ቤቱን መብራት አብራ');
    });

    test('treats the Ethiopic word space (U+1361) as whitespace', () {
      expect(n.normalize('መብራት፡አብር'), 'መብራት አብር');
    });

    test('collapses repeated spaces and removes zero-width characters', () {
      expect(n.normalize('light\u200B   1'), 'light 1');
      expect(n.normalize('\uFEFFturn   on\t the light'), 'turn on the light');
    });

    test('maps single Ethiopic digits to ASCII', () {
      expect(n.normalize('መብራት ፫'), 'መብራት 3');
      expect(n.normalize('light ፲'), 'light 10');
    });

    test('maps Arabic-Indic digits to ASCII', () {
      expect(n.normalize('light ٣'), 'light 3');
    });

    test('does NOT transliterate Ethiopic into Latin', () {
      // The whole point of §5.3: the script must be preserved.
      final out = n.normalize('አብር');
      expect(out, 'አብር');
      expect(n.containsLatin(out), isFalse);
    });

    test('returns empty for punctuation-only input', () {
      expect(n.normalize('   ...  '), '');
      expect(n.normalize('።'), '');
    });
  });

  group('tokens', () {
    test('splits on spaces and Ethiopic word space', () {
      expect(n.tokens('የመኝታ ቤቱን፡መብራት አብራ'),
          ['የመኝታ', 'ቤቱን', 'መብራት', 'አብራ']);
    });

    test('empty input yields no tokens', () {
      expect(n.tokens(''), isEmpty);
      expect(n.tokens('   '), isEmpty);
    });
  });

  group('language detection', () {
    test('Ethiopic only is am', () {
      expect(n.detectLanguage('መብራት አብር'), 'am');
    });

    test('Latin only is en', () {
      expect(n.detectLanguage('turn on light 1'), 'en');
    });

    test('Amharic sentence with an English device name is mixed', () {
      // A real case: the firmware names channels in Latin.
      expect(n.detectLanguage('የመኝታ ቤቱን Light 1 አብራ'), 'mixed');
    });

    test('no letters is unknown', () {
      expect(n.detectLanguage('123 ...'), 'unknown');
    });
  });
}
