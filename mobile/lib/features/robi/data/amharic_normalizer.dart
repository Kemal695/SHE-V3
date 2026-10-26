// =============================================================================
// SHE V3 — Amharic + language-neutral text normalization
// =============================================================================
// Spec: docs/voce command.md §5.3. Used by the command engine BEFORE any
// matching, so every downstream comparison sees the same text shape.
//
// DESIGN RULES (from the spec, and each one is load-bearing):
//   * Keep the original transcript for diagnostics; return a normalized COPY.
//   * Never transliterate Ethiopic -> Latin. Amharic ejectives (ብርሃን, አብር) have
//     no agreed Latin spelling, so a transliteration table is guesswork, and a
//     guessed match is exactly how the wrong device gets switched.
//   * Never apply broad character substitutions. Two Amharic words can differ by
//     one Ethiopic character; "cleaning" them together changes the meaning.
//   * Do not use edit distance as the execution decision. It is not computed
//     here at all.
//
// On Unicode normalization: Dart has no NFC in its core libraries, and this
// project does not depend on a normalization package. Ethiopic is a
// non-combining script (unlike Latin with accents), so the practical risk is
// zero-width joiners and duplicate spacing rather than canonical reordering.
// Both are handled explicitly below. If a normalization package is ever added,
// apply it as the first step here and keep these tests green.
// =============================================================================

/// Characters that are invisible but change string equality.
const Set<int> _zeroWidth = {
  0x200B, // zero-width space
  0x200C, // zero-width non-joiner
  0x200D, // zero-width joiner
  0x2060, // word joiner
  0xFEFF, // BOM / zero-width no-break space
};

/// Ethiopic punctuation that means "end of phrase" and must become a space
/// rather than disappearing (removing it would glue two words together).
const Set<int> _ethiopicSpacePunctuation = {
  0x1361, // ፡ ETHIOPIC WORDSPACE
  0x1362, // ። full stop
  0x1363, // ፣ comma
  0x1364, // ፤ semicolon
  0x1365, // ፥ colon
  0x1366, // ፦ preface colon
  0x1367, // ፧ question mark
  0x1368, // ፨ paragraph separator
};

/// Ethiopic numerals ፩..፲ -> 1..10, plus ፻ (100) and ፼ (10000).
///
/// Only the single-digit forms are mapped to ASCII: "light ፫" is a realistic
/// device reference ("Light 3"), while composed numerals (፲፩ = 11) need real
/// Ethiopic numeral arithmetic and are left untouched rather than half-converted.
const Map<int, String> _ethiopicDigits = {
  0x1369: '1',
  0x136A: '2',
  0x136B: '3',
  0x136C: '4',
  0x136D: '5',
  0x136E: '6',
  0x136F: '7',
  0x1370: '8',
  0x1371: '9',
  0x1372: '10',
};

/// Arabic-Indic digits ٠..٩ (used by some Amharic keyboards).
const Map<int, String> _arabicIndicDigits = {
  0x0660: '0',
  0x0661: '1',
  0x0662: '2',
  0x0663: '3',
  0x0664: '4',
  0x0665: '5',
  0x0666: '6',
  0x0667: '7',
  0x0668: '8',
  0x0669: '9',
};

/// Punctuation that carries no command meaning. Replaced with a space so
/// "Light 1." and "light 1" are the same input.
const String _latinPunctuation = r'.,!?:;"()[]{}<>/\\|@#$%^&*_=+~`';

class AmharicTextNormalizer {
  const AmharicTextNormalizer();

  /// Normalize for matching. Returns an empty string for input that carries no
  /// command content (whitespace, punctuation only).
  String normalize(String input) {
    if (input.isEmpty) return '';

    final out = StringBuffer();
    for (final rune in input.runes) {
      if (_zeroWidth.contains(rune)) continue;

      if (_ethiopicSpacePunctuation.contains(rune)) {
        out.write(' ');
        continue;
      }

      final ethiopicDigit = _ethiopicDigits[rune];
      if (ethiopicDigit != null) {
        out.write(ethiopicDigit);
        continue;
      }

      final arabicDigit = _arabicIndicDigits[rune];
      if (arabicDigit != null) {
        out.write(arabicDigit);
        continue;
      }

      if (rune < 128) {
        final ch = String.fromCharCode(rune);
        if (_latinPunctuation.contains(ch)) {
          out.write(' ');
          continue;
        }
        out.write(ch.toLowerCase());
        continue;
      }

      // Ethiopic letters, and anything else outside ASCII, pass through
      // untouched. Ethiopic has no case, so toLowerCase is a no-op there.
      out.write(String.fromCharCode(rune));
    }

    return _collapseSpaces(out.toString());
  }

  /// Normalized tokens. Ethiopic word space (U+1361) already became ' ' in
  /// [normalize], so a plain whitespace split is correct here.
  List<String> tokens(String input) {
    final n = normalize(input);
    if (n.isEmpty) return const [];
    return n.split(' ').where((t) => t.isNotEmpty).toList();
  }

  /// True when the text contains at least one Ethiopic character (U+1200–U+137F),
  /// i.e. it cannot be English.
  bool containsEthiopic(String input) =>
      input.runes.any((r) => r >= 0x1200 && r <= 0x137F);

  /// True when the text contains at least one Latin letter.
  bool containsLatin(String input) => input.runes.any(
        (r) => (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A),
      );

  /// Language label for the current utterance.
  ///
  /// "mixed" is a real case in Ethiopia: an Amharic sentence naming an English
  /// device ("የመኝታ ቤቱን Light 1 አብራ"). It is reported, not corrected.
  String detectLanguage(String input) {
    final am = containsEthiopic(input);
    final en = containsLatin(input);
    if (am && en) return 'mixed';
    if (am) return 'am';
    if (en) return 'en';
    return 'unknown';
  }

  static String _collapseSpaces(String s) {
    final buf = StringBuffer();
    var lastSpace = true; // trims leading spaces
    for (final rune in s.runes) {
      final isSpace = rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;
      if (isSpace) {
        if (!lastSpace) {
          buf.write(' ');
          lastSpace = true;
        }
        continue;
      }
      buf.write(String.fromCharCode(rune));
      lastSpace = false;
    }
    final out = buf.toString();
    return out.endsWith(' ') ? out.substring(0, out.length - 1) : out;
  }
}

/// Shared instance — normalization is stateless.
const amharicNormalizer = AmharicTextNormalizer();
