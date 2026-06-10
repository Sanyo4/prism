import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/ui.dart';

void main() {
  group('SpaceTokens.mobile()', () {
    const tokens = SpaceTokens.mobile();

    test('exact constants from slice 7 §7', () {
      expect(tokens.s1, 4);
      expect(tokens.s2, 8);
      expect(tokens.s3, 12);
      expect(tokens.s4, 16);
      expect(tokens.s6, 24);
      expect(tokens.s8, 32);
      expect(tokens.s12, 48);
    });

    test('sequence matches the locked {4, 8, 12, 16, 24, 32, 48}', () {
      // Slice 7's verification step 4 measures vertical rhythm against
      // this exact set; assert it explicitly.
      const expected = <double>[4, 8, 12, 16, 24, 32, 48];
      final actual = <double>[
        tokens.s1,
        tokens.s2,
        tokens.s3,
        tokens.s4,
        tokens.s6,
        tokens.s8,
        tokens.s12,
      ];
      expect(actual, expected);
    });

    test('s4 is the base "card padding" 16', () {
      expect(tokens.s4, 16);
    });
  });

  group('SpaceTokens.lerp', () {
    test('against itself is identity-equivalent at any t', () {
      const a = SpaceTokens.mobile();
      const b = SpaceTokens.mobile();
      final mid = a.lerp(b, 0.5);
      expect(mid.s1, a.s1);
      expect(mid.s2, a.s2);
      expect(mid.s3, a.s3);
      expect(mid.s4, a.s4);
      expect(mid.s6, a.s6);
      expect(mid.s8, a.s8);
      expect(mid.s12, a.s12);
    });

    test('interpolates channel-wise to a non-mobile profile', () {
      const a = SpaceTokens.mobile();
      const b = SpaceTokens(s1: 8, s2: 16, s3: 24, s4: 32, s6: 48, s8: 64, s12: 96);
      final mid = a.lerp(b, 0.5);
      expect(mid.s1, 6); // (4 + 8) / 2
      expect(mid.s4, 24); // (16 + 32) / 2
      expect(mid.s12, 72); // (48 + 96) / 2
    });

    test('returns this when other is not a SpaceTokens', () {
      const a = SpaceTokens.mobile();
      // ignore: avoid_redundant_argument_values
      final result = a.lerp(null, 0.5);
      expect(result.s4, a.s4);
    });
  });

  group('SpaceTokens.copyWith', () {
    test('overrides only the named field', () {
      const a = SpaceTokens.mobile();
      final b = a.copyWith(s4: 20);
      expect(b.s4, 20);
      expect(b.s1, a.s1);
      expect(b.s12, a.s12);
    });
  });
}
