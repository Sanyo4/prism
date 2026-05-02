import 'package:prism_playlist_engine/camelot.dart';
import 'package:test/test.dart';

void main() {
  group('Camelot.parse — 24-entry table', () {
    // Locked table: every entry is the canonical Camelot mapping
    // for the standard major-minor wheel. Both flat and sharp
    // enharmonics map to the same wheel slot.
    final cases = <String, CamelotKey>{
      // Major (B-ring)
      'C': const CamelotKey(8, minor: false),
      'C#': const CamelotKey(3, minor: false),
      'Db': const CamelotKey(3, minor: false),
      'D': const CamelotKey(10, minor: false),
      'D#': const CamelotKey(5, minor: false),
      'Eb': const CamelotKey(5, minor: false),
      'E': const CamelotKey(12, minor: false),
      'F': const CamelotKey(7, minor: false),
      'F#': const CamelotKey(2, minor: false),
      'Gb': const CamelotKey(2, minor: false),
      'G': const CamelotKey(9, minor: false),
      'G#': const CamelotKey(4, minor: false),
      'Ab': const CamelotKey(4, minor: false),
      'A': const CamelotKey(11, minor: false),
      'A#': const CamelotKey(6, minor: false),
      'Bb': const CamelotKey(6, minor: false),
      'B': const CamelotKey(1, minor: false),
      // Minor (A-ring)
      'Cm': const CamelotKey(5, minor: true),
      'C#m': const CamelotKey(12, minor: true),
      'Dbm': const CamelotKey(12, minor: true),
      'Dm': const CamelotKey(7, minor: true),
      'D#m': const CamelotKey(2, minor: true),
      'Ebm': const CamelotKey(2, minor: true),
      'Em': const CamelotKey(9, minor: true),
      'Fm': const CamelotKey(4, minor: true),
      'F#m': const CamelotKey(11, minor: true),
      'Gbm': const CamelotKey(11, minor: true),
      'Gm': const CamelotKey(6, minor: true),
      'G#m': const CamelotKey(1, minor: true),
      'Abm': const CamelotKey(1, minor: true),
      'Am': const CamelotKey(8, minor: true),
      'A#m': const CamelotKey(3, minor: true),
      'Bbm': const CamelotKey(3, minor: true),
      'Bm': const CamelotKey(10, minor: true),
    };

    for (final entry in cases.entries) {
      test('parses "${entry.key}"', () {
        expect(Camelot.parse(entry.key), entry.value);
      });
    }

    test('expanded spellings collapse to canonical form', () {
      expect(Camelot.parse('F minor'), const CamelotKey(4, minor: true));
      expect(Camelot.parse('C major'), const CamelotKey(8, minor: false));
      expect(Camelot.parse('  F#m  '), const CamelotKey(11, minor: true));
      expect(Camelot.parse('Cmaj'), const CamelotKey(8, minor: false));
      expect(Camelot.parse('Cmin'), const CamelotKey(5, minor: true));
    });

    test('returns null on garbage input', () {
      expect(Camelot.parse(''), isNull);
      expect(Camelot.parse('not-a-key'), isNull);
      expect(Camelot.parse('H#'), isNull);
    });
  });

  group('Camelot.distance — spot checks', () {
    test('parallel keys are distance 1 (4A↔4B)', () {
      expect(
        Camelot.distance(
          const CamelotKey(4, minor: true),
          const CamelotKey(4, minor: false),
        ),
        1,
      );
    });

    test('adjacent same-tonality is distance 1 (4A↔5A)', () {
      expect(
        Camelot.distance(
          const CamelotKey(4, minor: true),
          const CamelotKey(5, minor: true),
        ),
        1,
      );
    });

    test('half-wheel same-tonality is distance 6 (4A↔10A)', () {
      expect(
        Camelot.distance(
          const CamelotKey(4, minor: true),
          const CamelotKey(10, minor: true),
        ),
        6,
      );
    });

    test('two-step plus tonality flip → 3', () {
      expect(
        Camelot.distance(
          const CamelotKey(4, minor: true),
          const CamelotKey(6, minor: false),
        ),
        3,
      );
    });

    test('symmetry', () {
      const a = CamelotKey(7, minor: true);
      const b = CamelotKey(11, minor: false);
      expect(Camelot.distance(a, b), Camelot.distance(b, a));
    });
  });

  group('Camelot.compatibilityBonus — step function', () {
    test('distance ≤ 1 → bonus', () {
      const a = CamelotKey(4, minor: true);
      const b = CamelotKey(5, minor: true); // distance 1
      expect(Camelot.compatibilityBonus(a, b), greaterThan(1.0));
    });

    test('distance == 2 → no-op', () {
      const a = CamelotKey(4, minor: true);
      const b = CamelotKey(6, minor: true); // distance 2
      expect(Camelot.compatibilityBonus(a, b), 1.0);
    });

    test('distance ≥ 3 → penalty', () {
      const a = CamelotKey(4, minor: true);
      const b = CamelotKey(10, minor: true); // distance 6
      expect(Camelot.compatibilityBonus(a, b), lessThan(1.0));
    });
  });
}
