import 'dart:math' as math;

import 'package:meta/meta.dart';

/// One position on the Camelot wheel. `number` is 1..12; `minor=true`
/// is the inner "A" ring (minor keys), `false` is the outer "B" ring.
@immutable
class CamelotKey {
  final int number;
  final bool minor;
  const CamelotKey(this.number, {required this.minor})
      : assert(number >= 1 && number <= 12, 'number must be in [1,12]');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CamelotKey && other.number == number && other.minor == minor);

  @override
  int get hashCode => Object.hash(number, minor);

  @override
  String toString() => '$number${minor ? 'A' : 'B'}';
}

/// Camelot wheel parser + distance helper. Locked by `flow_test.dart`
/// for slice-6 reuse; this file ships zero radio-specific state.
///
/// Distance:
/// `min(Δn mod 12, 12 − Δn mod 12) + (minorDiffers ? 1 : 0)` where Δn
/// is the wheel-position difference. Range 0..7 in principle; in
/// practice the worst-case meaningful value is 6 (across-the-wheel
/// + tonality flip would be 7, which we collapse to 6 to keep the
/// FlowScorer's bonus/penalty step function symmetric).
class Camelot {
  Camelot._();

  /// Parse the 24 standard Essentia spellings into Camelot positions.
  /// Returns null on unknown input — `FlowScorer` treats that as
  /// "neither bonus nor penalty, never reject" (§10 risk 11).
  ///
  /// Accepted input forms (case-insensitive, whitespace-trimmed):
  ///   - `C`, `Cm`, `C#`, `C#m`, `Db`, `Dbm`, ...
  ///   - `C major`, `C minor`, `Cmaj`, `Cmin`
  static CamelotKey? parse(String rawKey) {
    final s = rawKey.trim();
    if (s.isEmpty) return null;
    return _table[_normalize(s)];
  }

  /// 0..6 distance on the wheel. Adjacent (`4A↔5A`) = 1, parallel
  /// (`4A↔4B`) = 1, half-wheel (`4A↔10A`) = 6.
  static int distance(CamelotKey a, CamelotKey b) {
    final dn = (a.number - b.number).abs() % 12;
    final wheel = math.min(dn, 12 - dn);
    final tonality = a.minor == b.minor ? 0 : 1;
    final raw = wheel + tonality;
    // Cap so the +1 tonality at the wheel-opposite (6+1) doesn't
    // overshoot — slice 5's FlowScorer treats anything ≥ 3 the same.
    return raw > 6 ? 6 : raw;
  }

  /// Multiplicative bonus to fold into the final pick score.
  /// Symmetric with [FlowScorer]'s `camelotBonusAt1` /
  /// `camelotPenaltyAt3`; the helper here returns the step function
  /// using those default thresholds. The actual numeric values live
  /// on `FlowScorer` as configurable knobs.
  static double compatibilityBonus(
    CamelotKey a,
    CamelotKey b, {
    double bonusAt1 = 1.15,
    double penaltyAt3 = 0.85,
  }) {
    final d = distance(a, b);
    if (d <= 1) return bonusAt1;
    if (d >= 3) return penaltyAt3;
    return 1.0; // d == 2
  }

  // Normalize spellings to a canonical key for the lookup table.
  // Strips spaces, lowercases everything, collapses 'maj'/'major'/'M'
  // to the major form and 'min'/'minor'/'m' to the minor form.
  static String _normalize(String raw) {
    var s = raw.toLowerCase().replaceAll(' ', '');
    if (s.endsWith('major')) s = s.substring(0, s.length - 5);
    if (s.endsWith('maj')) s = s.substring(0, s.length - 3);
    if (s.endsWith('minor')) {
      s = '${s.substring(0, s.length - 5)}m';
    } else if (s.endsWith('min')) {
      s = '${s.substring(0, s.length - 3)}m';
    }
    return s;
  }

  /// 24-entry lookup, indexed by normalized spelling. Locked by
  /// `camelot_test.dart`. Both flat and sharp enharmonics map to the
  /// same Camelot position.
  ///
  /// Major (B-ring) wheel order: 8B=C, 3B=Db, 10B=D, 5B=Eb, 12B=E,
  /// 7B=F, 2B=F#/Gb, 9B=G, 4B=Ab, 11B=A, 6B=Bb, 1B=B.
  /// Minor (A-ring) — relative minor of each major sits at the same
  /// number on the inner ring: 8A=Am, 3A=Bbm, 10A=Bm, 5A=Cm, 12A=C#m,
  /// 7A=Dm, 2A=Ebm/D#m, 9A=Em, 4A=Fm, 11A=F#m, 6A=Gm, 1A=G#m/Abm.
  static final Map<String, CamelotKey> _table = {
    // Major (B-ring)
    'c': const CamelotKey(8, minor: false),
    'c#': const CamelotKey(3, minor: false),
    'db': const CamelotKey(3, minor: false),
    'd': const CamelotKey(10, minor: false),
    'd#': const CamelotKey(5, minor: false),
    'eb': const CamelotKey(5, minor: false),
    'e': const CamelotKey(12, minor: false),
    'f': const CamelotKey(7, minor: false),
    'f#': const CamelotKey(2, minor: false),
    'gb': const CamelotKey(2, minor: false),
    'g': const CamelotKey(9, minor: false),
    'g#': const CamelotKey(4, minor: false),
    'ab': const CamelotKey(4, minor: false),
    'a': const CamelotKey(11, minor: false),
    'a#': const CamelotKey(6, minor: false),
    'bb': const CamelotKey(6, minor: false),
    'b': const CamelotKey(1, minor: false),
    // Minor (A-ring)
    'cm': const CamelotKey(5, minor: true),
    'c#m': const CamelotKey(12, minor: true),
    'dbm': const CamelotKey(12, minor: true),
    'dm': const CamelotKey(7, minor: true),
    'd#m': const CamelotKey(2, minor: true),
    'ebm': const CamelotKey(2, minor: true),
    'em': const CamelotKey(9, minor: true),
    'fm': const CamelotKey(4, minor: true),
    'f#m': const CamelotKey(11, minor: true),
    'gbm': const CamelotKey(11, minor: true),
    'gm': const CamelotKey(6, minor: true),
    'g#m': const CamelotKey(1, minor: true),
    'abm': const CamelotKey(1, minor: true),
    'am': const CamelotKey(8, minor: true),
    'a#m': const CamelotKey(3, minor: true),
    'bbm': const CamelotKey(3, minor: true),
    'bm': const CamelotKey(10, minor: true),
  };
}
