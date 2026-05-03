import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import 'aurora_background.dart';

/// Five locked preset accents (slice 7 §2 / §7). User picks the
/// default in Settings → Theme; default-default is `blue`.
enum PresetAccent { blue, pink, mint, amber, lilac }

/// Locked preset values. Slice 7's verification step 8 asserts these
/// **exact** ARGB tuples — do not adjust without bumping the spec.
const Map<PresetAccent, Color> kPresetAccents = <PresetAccent, Color>{
  PresetAccent.blue: Color(0xFF6BA8FF),
  PresetAccent.pink: Color(0xFFFFA0C8),
  PresetAccent.mint: Color(0xFFA0E8C4),
  PresetAccent.amber: Color(0xFFFFC878),
  PresetAccent.lilac: Color(0xFFC0A0FF),
};

/// Per-route accent palette used by the two hero surfaces
/// (album-detail and now-playing) — every other route reads
/// [AlbumPalette.neutral] (slice 7 §2 / §5).
///
/// Channels:
/// - [dominant] drives the scrub-bar, play-button gradient,
///   chip-bg tint, and the primary blob hue inside
///   [AuroraBackground] when the variant honors the override.
/// - [secondary] is a complementary tone — used for the second
///   Aurora blob and for the chip text-on-tint surface.
/// - [textOnDominant] is the legibility-corrected text color
///   that goes on top of [dominant] (white on dark dominants,
///   near-black on pale dominants).
/// - [variant] picks which Aurora layer the screen wraps in.
/// - [isNeutral] is a sentinel — when true the palette came from
///   [AlbumPalette.neutral] (no art, sparse-chroma fallback, or
///   a route that opts out) and consumers should render
///   without album tinting.
@immutable
class AlbumPalette extends ThemeExtension<AlbumPalette> {
  const AlbumPalette({
    required this.dominant,
    required this.secondary,
    required this.textOnDominant,
    required this.variant,
    required this.isNeutral,
  });

  /// Locked sentinel: preset blue + Aurora `home`. Apps boot with
  /// this in `ThemeData.extensions`; only the two hero routes
  /// override it.
  const AlbumPalette.neutral()
    : dominant = const Color(0xFF6BA8FF),
      secondary = const Color(0xFFFFA0C8),
      textOnDominant = Colors.white,
      variant = AuroraVariant.home,
      isNeutral = true;

  final Color dominant;
  final Color secondary;
  final Color textOnDominant;
  final AuroraVariant variant;
  final bool isNeutral;

  /// Build from one of the five locked presets. Picks the *next*
  /// preset (mod 5) as the secondary, so e.g. `blue` pairs with
  /// `pink`, `pink` pairs with `mint`, etc. Variant defaults to
  /// `album` so a preset-driven palette is meaningful on the
  /// album-detail route.
  factory AlbumPalette.preset(PresetAccent p) {
    final dominant = kPresetAccents[p]!;
    final values = kPresetAccents.values.toList();
    final secondary = values[(p.index + 1) % values.length];
    return AlbumPalette(
      dominant: dominant,
      secondary: secondary,
      textOnDominant: _textOn(dominant),
      variant: AuroraVariant.album,
      isNeutral: false,
    );
  }

  /// Build from a [PaletteGenerator] swatch set. Pick priority is
  /// `vibrantColor → dominantColor → mutedColor → lightVibrantColor
  /// → darkVibrantColor` — first non-null wins. If the picked
  /// dominant scores below the [chromaOf] threshold (0.15 — slice
  /// 7 §10 risk 1) the result falls back to
  /// [AlbumPalette.preset] using [fallback].
  ///
  /// Variant is always `album` here; the now-playing route swaps it
  /// to `player` via [copyWith].
  factory AlbumPalette.fromSwatches(
    PaletteGenerator g, {
    required PresetAccent fallback,
  }) {
    final picks = <PaletteColor? Function()>[
      () => g.vibrantColor,
      () => g.dominantColor,
      () => g.mutedColor,
      () => g.lightVibrantColor,
      () => g.darkVibrantColor,
    ];
    PaletteColor? chosen;
    for (final pick in picks) {
      chosen = pick();
      if (chosen != null) break;
    }
    if (chosen == null || chromaOf(chosen.color) < 0.15) {
      return AlbumPalette.preset(fallback);
    }
    final dominant = chosen.color;
    final secondary = g.lightMutedColor?.color ??
        g.darkMutedColor?.color ??
        dominant.withValues(alpha: 0.7);
    return AlbumPalette(
      dominant: dominant,
      secondary: secondary,
      textOnDominant: _textOn(dominant),
      variant: AuroraVariant.album,
      isNeutral: false,
    );
  }

  @override
  AlbumPalette copyWith({
    Color? dominant,
    Color? secondary,
    Color? textOnDominant,
    AuroraVariant? variant,
    bool? isNeutral,
  }) {
    return AlbumPalette(
      dominant: dominant ?? this.dominant,
      secondary: secondary ?? this.secondary,
      textOnDominant: textOnDominant ?? this.textOnDominant,
      variant: variant ?? this.variant,
      isNeutral: isNeutral ?? this.isNeutral,
    );
  }

  @override
  AlbumPalette lerp(covariant ThemeExtension<AlbumPalette>? other, double t) {
    if (other is! AlbumPalette) return this;
    // Channel-wise sRGB lerp on the three colors. Variant + flag
    // snap at t >= 0.5 — flight is ≤ 300 ms so the snap is invisible
    // (slice 7 §7).
    return AlbumPalette(
      dominant: Color.lerp(dominant, other.dominant, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      textOnDominant: Color.lerp(textOnDominant, other.textOnDominant, t)!,
      variant: t >= 0.5 ? other.variant : variant,
      isNeutral: t >= 0.5 ? other.isNeutral : isNeutral,
    );
  }
}

/// HSL saturation × luminance-weighted "perceived chroma". Slice 7
/// §10 risk 1: a desaturated cover (gray sleeve, sepia photograph)
/// scores near-zero, so [AlbumPalette.fromSwatches] can punt to
/// the user's selected preset rather than tint the route a muddy
/// brown.
///
/// Threshold used by [AlbumPalette.fromSwatches]: `0.15`.
double chromaOf(Color c) {
  final hsl = HSLColor.fromColor(c);
  final luminance = c.computeLuminance();
  // Saturation × (0.6 + 0.4 × Y). Bright saturated colors clear
  // 0.6+; mid-gray sits near 0; dark saturated colors stay below
  // 0.45 because the luminance term compresses them. Tuned on the
  // fixture set in `palette_test.dart`.
  return hsl.saturation * (0.6 + 0.4 * luminance);
}

Color _textOn(Color background) {
  return background.computeLuminance() > 0.5
      ? const Color(0xFF111111)
      : Colors.white;
}
