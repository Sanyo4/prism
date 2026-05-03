import 'package:flutter/material.dart';
import 'package:prism_ui/ui.dart';

/// Composes [ThemeData] from the three Track A `ThemeExtension`s
/// (`SpaceTokens`, `TypographyScale`, `AlbumPalette`) plus a Material 3
/// [ColorScheme] seeded by the user's chosen preset accent.
///
/// Slice 7 §5 / §8 step 4: only **one** `ColorScheme.fromSeed` call ever
/// runs (at app boot, with the default preset blue). Per-album tinting
/// flows through the additive [AlbumPalette] extension on the two hero
/// surfaces — never through `fromSeed` again.
///
/// Fonts: [TypographyScale.prism] sets `SF Pro Display → Inter → Geist`
/// at the family-list level. SF Pro is opportunistic on Apple devices;
/// Inter + Geist are bundled assets under `apps/mobile/assets/fonts/`
/// (binaries pending — see [_fontsTodo] for the drop-in instructions).
///
/// TODO(slice-7-fonts): The `flutter.fonts:` block in
/// `apps/mobile/pubspec.yaml` is gated on the binaries actually being
/// present on disk; declaring an asset that doesn't exist makes
/// `flutter pub get` fail. The current build uses `google_fonts`
/// (network-disabled per slice 7 §10 risk 5) for Inter resolution; once
/// `Inter-{Regular,Medium,SemiBold,Bold}.ttf` and
/// `Geist-{Regular,Medium}.ttf` are dropped under
/// `apps/mobile/assets/fonts/`, uncomment the `flutter.fonts:` block in
/// pubspec.yaml so the bundled assets win the family resolution race.

class PrismTheme {
  PrismTheme._();

  /// Builds the app-wide [ThemeData].
  ///
  /// [defaultPreset] seeds [ColorScheme.fromSeed] and is the value
  /// shown on every non-hero route via [AlbumPalette.neutral]. The
  /// hero routes (album-detail, now-playing) override the
  /// `AlbumPalette` entry per-album via `Theme(data: ..copyWith)` —
  /// the seed [ColorScheme] never changes per-album (slice 7 §5).
  static ThemeData light({PresetAccent defaultPreset = PresetAccent.blue}) {
    final seed = kPresetAccents[defaultPreset]!;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    final typography = TypographyScale.prism();
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: typography.toMaterialTextTheme(),
      // Slice 7 §5: three extensions in `ThemeData.extensions`.
      // `AlbumPalette.neutral` is the sentinel; album-detail and
      // now-playing routes override it via `Theme(data: ..copyWith)`.
      extensions: <ThemeExtension<dynamic>>[
        const SpaceTokens.mobile(),
        typography,
        const AlbumPalette.neutral(),
      ],
    );
  }
}
