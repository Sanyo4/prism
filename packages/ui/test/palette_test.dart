import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:prism_ui/ui.dart';

void main() {
  group('kPresetAccents — locked values per slice 7 §7', () {
    test('exact ARGB tuples', () {
      expect(kPresetAccents[PresetAccent.blue], const Color(0xFF6BA8FF));
      expect(kPresetAccents[PresetAccent.pink], const Color(0xFFFFA0C8));
      expect(kPresetAccents[PresetAccent.mint], const Color(0xFFA0E8C4));
      expect(kPresetAccents[PresetAccent.amber], const Color(0xFFFFC878));
      expect(kPresetAccents[PresetAccent.lilac], const Color(0xFFC0A0FF));
    });

    test('exactly five entries — no extras', () {
      expect(kPresetAccents.length, 5);
      expect(kPresetAccents.keys.toSet(), PresetAccent.values.toSet());
    });
  });

  group('AlbumPalette.neutral()', () {
    const neutral = AlbumPalette.neutral();

    test('isNeutral is true and dominant is preset blue', () {
      expect(neutral.isNeutral, true);
      expect(neutral.dominant, const Color(0xFF6BA8FF));
    });

    test('variant is home — neutral routes opt out of album tinting', () {
      expect(neutral.variant, AuroraVariant.home);
    });

    test('textOnDominant is white (0xFF6BA8FF is dark enough)', () {
      expect(neutral.textOnDominant, Colors.white);
    });
  });

  group('chromaOf', () {
    test('mid-gray scores below 0.15 — falls into the preset gate', () {
      expect(chromaOf(const Color(0xFF808080)), lessThan(0.15));
    });

    test('coral red scores well above 0.5', () {
      expect(chromaOf(const Color(0xFFFF6B6B)), greaterThan(0.5));
    });

    test('pure white scores 0 (no saturation)', () {
      expect(chromaOf(const Color(0xFFFFFFFF)), 0);
    });

    test('pure black scores 0 (no saturation)', () {
      expect(chromaOf(const Color(0xFF000000)), 0);
    });

    test('vibrant blue clears the 0.15 threshold', () {
      expect(chromaOf(const Color(0xFF6BA8FF)), greaterThan(0.15));
    });
  });

  group('AlbumPalette.preset', () {
    test('blue → dominant is preset blue, secondary is preset pink', () {
      final p = AlbumPalette.preset(PresetAccent.blue);
      expect(p.dominant, const Color(0xFF6BA8FF));
      expect(p.secondary, const Color(0xFFFFA0C8));
      expect(p.isNeutral, false);
      expect(p.variant, AuroraVariant.album);
    });

    test('lilac wraps around to blue as secondary', () {
      final p = AlbumPalette.preset(PresetAccent.lilac);
      expect(p.dominant, const Color(0xFFC0A0FF));
      expect(p.secondary, const Color(0xFF6BA8FF));
    });
  });

  group('AlbumPalette.fromSwatches', () {
    test('falls back to preset when vibrantColor is mid-gray', () {
      // Hand-build a PaletteGenerator whose only swatch is gray.
      // chromaOf(0xFF808080) ≈ 0 → < 0.15 → preset fallback.
      final g = PaletteGenerator.fromColors(<PaletteColor>[
        PaletteColor(const Color(0xFF808080), 100),
      ]);
      final palette =
          AlbumPalette.fromSwatches(g, fallback: PresetAccent.blue);
      expect(palette.dominant, const Color(0xFF6BA8FF));
      expect(palette.secondary, const Color(0xFFFFA0C8));
      expect(palette.isNeutral, false);
    });

    test('falls back to preset when no swatches are present', () {
      final g = PaletteGenerator.fromColors(const <PaletteColor>[]);
      final palette =
          AlbumPalette.fromSwatches(g, fallback: PresetAccent.mint);
      expect(palette.dominant, const Color(0xFFA0E8C4));
    });

    test('uses a saturated swatch when one is available', () {
      // Coral red, large population. PaletteGenerator's
      // _generateScores will treat it as the dominant when it's
      // the only swatch.
      final g = PaletteGenerator.fromColors(<PaletteColor>[
        PaletteColor(const Color(0xFFFF6B6B), 1000),
      ]);
      final palette =
          AlbumPalette.fromSwatches(g, fallback: PresetAccent.blue);
      // Either vibrantColor or dominantColor is set to the coral;
      // either way it clears the chroma gate, so isNeutral=false
      // and dominant is the coral.
      expect(palette.isNeutral, false);
      expect(palette.dominant, const Color(0xFFFF6B6B));
    });
  });

  group('AlbumPalette.lerp', () {
    test('interpolates dominant channel-wise to the average', () {
      const a = AlbumPalette(
        dominant: Color(0xFF000000),
        secondary: Color(0xFF000000),
        textOnDominant: Colors.white,
        variant: AuroraVariant.home,
        isNeutral: false,
      );
      const b = AlbumPalette(
        dominant: Color(0xFFFFFFFF),
        secondary: Color(0xFFFFFFFF),
        textOnDominant: Colors.black,
        variant: AuroraVariant.album,
        isNeutral: true,
      );
      final mid = a.lerp(b, 0.5);
      // (0x00 + 0xFF) / 2 ≈ 0x7F — Color.lerp uses sRGB linear so
      // the midpoint is around 0x7F or 0x80 per channel.
      final r = (mid.dominant.r * 255).round();
      final g = (mid.dominant.g * 255).round();
      final bChannel = (mid.dominant.b * 255).round();
      expect(r, inInclusiveRange(0x7E, 0x81));
      expect(g, inInclusiveRange(0x7E, 0x81));
      expect(bChannel, inInclusiveRange(0x7E, 0x81));
    });

    test('variant snaps at t >= 0.5', () {
      const a = AlbumPalette.neutral();
      final b = AlbumPalette.preset(PresetAccent.pink);
      // t = 0.4 → still home.
      expect(a.lerp(b, 0.4).variant, AuroraVariant.home);
      // t = 0.5 → flips to album.
      expect(a.lerp(b, 0.5).variant, AuroraVariant.album);
      // t = 0.6 → album.
      expect(a.lerp(b, 0.6).variant, AuroraVariant.album);
    });

    test('returns this when other is not AlbumPalette', () {
      const a = AlbumPalette.neutral();
      final result = a.lerp(null, 0.5);
      expect(result.dominant, a.dominant);
    });
  });

  group('AlbumPalette.copyWith', () {
    test('overrides only the named field', () {
      final a = AlbumPalette.preset(PresetAccent.blue);
      final b = a.copyWith(variant: AuroraVariant.player);
      expect(b.variant, AuroraVariant.player);
      expect(b.dominant, a.dominant);
      expect(b.secondary, a.secondary);
      expect(b.isNeutral, a.isNeutral);
    });
  });
}
