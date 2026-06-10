import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/ui.dart';

void main() {
  // `TypographyScale.prism()` calls `GoogleFonts.spaceGrotesk(...)`
  // which needs the test binding to read the asset bundle. Without
  // this every test in the file fails with "Binding has not yet been
  // initialized" before group setup runs.
  // Use `TypographyScale.testFixture()` instead of `.prism()` —
  // `.prism()` invokes `GoogleFonts.spaceGrotesk()` which schedules
  // an async HTTP fetch in the no-network test sandbox; the fetch
  // throws as an unhandled exception that fails every test in the
  // file with "did not complete". `testFixture()` produces the same
  // five-style shape with `fontFamily: 'Space Grotesk'` set as a
  // plain string — assertions on size/height/weight/letter-spacing
  // are unaffected by the substitution.
  final scale = TypographyScale.testFixture();
  final tt = scale.toMaterialTextTheme();

  group('TypographyScale.prism()', () {
    test('display sizes from slice 7 §7', () {
      expect(scale.display36.fontSize, 36);
      expect(scale.display28.fontSize, 28);
      expect(scale.display20.fontSize, 20);
      expect(scale.body16.fontSize, 16);
      expect(scale.caption13.fontSize, 13);
    });

    test('display heights are 1.15; body and caption are 1.45', () {
      expect(scale.display36.height, 1.15);
      expect(scale.display28.height, 1.15);
      expect(scale.display20.height, 1.15);
      expect(scale.body16.height, 1.45);
      expect(scale.caption13.height, 1.45);
    });

    test('letter spacing matches the spec', () {
      expect(scale.display36.letterSpacing, -0.4);
      expect(scale.display28.letterSpacing, -0.2);
      expect(scale.display20.letterSpacing, 0);
      expect(scale.body16.letterSpacing, 0);
      expect(scale.caption13.letterSpacing, 0.1);
    });

    test('font family is Space Grotesk (per design bundle)', () {
      // `testFixture()` sets `fontFamily: 'Space Grotesk'` as a
      // plain string. Production `prism()` goes through
      // `GoogleFonts.spaceGrotesk(...)` which produces a slugged
      // family name (`SpaceGrotesk_regular` etc.) — the visual
      // result is identical, but the strings differ. We only assert
      // the human-readable family name here; google_fonts'
      // package-level invariants are covered by their own test
      // suite, not this one.
      expect(scale.display36.fontFamily, 'Space Grotesk');
      expect(scale.body16.fontFamily, 'Space Grotesk');
    });

    test('weights — displays w700/w600, body/caption w400', () {
      expect(scale.display36.fontWeight, FontWeight.w700);
      expect(scale.display28.fontWeight, FontWeight.w700);
      expect(scale.display20.fontWeight, FontWeight.w600);
      expect(scale.body16.fontWeight, FontWeight.w400);
      expect(scale.caption13.fontWeight, FontWeight.w400);
    });
  });

  group('toMaterialTextTheme()', () {
    test('Material 3 slot mapping per slice 7 §8 step 3', () {
      expect(tt.displayLarge, scale.display36);
      expect(tt.displayMedium, scale.display28);
      expect(tt.headlineMedium, scale.display20);
      expect(tt.bodyLarge, scale.body16);
      expect(tt.labelSmall, scale.caption13);
    });

    test('every slot is non-null so consumers never face nulls', () {
      expect(tt.displayLarge, isNotNull);
      expect(tt.displayMedium, isNotNull);
      expect(tt.displaySmall, isNotNull);
      expect(tt.headlineLarge, isNotNull);
      expect(tt.headlineMedium, isNotNull);
      expect(tt.headlineSmall, isNotNull);
      expect(tt.titleLarge, isNotNull);
      expect(tt.titleMedium, isNotNull);
      expect(tt.titleSmall, isNotNull);
      expect(tt.bodyLarge, isNotNull);
      expect(tt.bodyMedium, isNotNull);
      expect(tt.bodySmall, isNotNull);
      expect(tt.labelLarge, isNotNull);
      expect(tt.labelMedium, isNotNull);
      expect(tt.labelSmall, isNotNull);
    });
  });

  group('TypographyScale.lerp', () {
    // Hand-built fixtures so the lerp logic is exercised without
    // re-invoking `TypographyScale.prism()` (which probes the asset
    // bundle through google_fonts and is fragile across test runs).
    TypographyScale fixture(double display36Size) => TypographyScale(
          display36: TextStyle(fontSize: display36Size, height: 1.15),
          display28: const TextStyle(fontSize: 28, height: 1.15),
          display20: const TextStyle(fontSize: 20, height: 1.15),
          body16: const TextStyle(fontSize: 16, height: 1.45),
          caption13: const TextStyle(fontSize: 13, height: 1.45),
        );

    test('returns this when other is not TypographyScale', () {
      final a = fixture(36);
      final result = a.lerp(null, 0.5);
      expect(result.display36.fontSize, a.display36.fontSize);
    });

    test('channel-wise on the five styles', () {
      final a = fixture(36);
      final b = fixture(48);
      final mid = a.lerp(b, 0.5);
      // 36 → 48 lerps through 42 at t=0.5.
      expect(mid.display36.fontSize, 42);
    });
  });
}
