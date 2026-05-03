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
  ///
  /// Slice 7 §13 — wireframe is the Y2K Aero "made of light and
  /// glass" interior: warm cream paper with pastel lilac / pink /
  /// mint aurora blobs and dark text. The previous default rendered
  /// the AppBar + BottomNavigationBar with their M3 default opaque
  /// `surface` color — the same near-white as the cream aurora —
  /// which is why the user reported "white on white" on phones.
  ///
  /// The fix is to keep the brightness light (so dark text wins on
  /// the cream aurora) but force the AppBar fully transparent and
  /// the BottomNavigationBar to a slightly translucent paper tint
  /// so the aurora bleeds through both regions, matching the
  /// wireframe.
  static ThemeData light({PresetAccent defaultPreset = PresetAccent.blue}) {
    final seed = kPresetAccents[defaultPreset]!;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      // Cream paper to match the aurora base — keeps Material's
      // surface roles aligned with the AuroraBackground tone so
      // surface-tinted widgets (Cards, dialogs) don't fight the
      // page bg with a different shade of white.
      surface: const Color(0xFFFBF7F2),
      onSurface: const Color(0xFF2A2730),
    );
    final typography = TypographyScale.prism();
    // Soft glass paper tint for the bottom nav — cream at 70%
    // alpha lets the aurora bleed through but stays opaque enough
    // to keep the icons legible.
    final navTint = const Color(0xFFFBF7F2).withValues(alpha: 0.70);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      // Scaffold default is transparent so the AuroraBackground at the
      // shell layer paints through every route.
      scaffoldBackgroundColor: Colors.transparent,
      // Header (AppBar) — transparent + zero elevation so the aurora
      // shows through; dark foreground for icons + title (the text
      // sits on cream paper).
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
        iconTheme: IconThemeData(color: scheme.onSurface),
        titleTextStyle: typography.display20.copyWith(
          color: scheme.onSurface,
        ),
      ),
      // Footer (BottomNavigationBar) — translucent paper so the
      // aurora bleeds through but icons stay legible. Selected →
      // preset accent, unselected → muted onSurface.
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: navTint,
        selectedItemColor: seed,
        unselectedItemColor: scheme.onSurface.withValues(alpha: 0.55),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
      // TabBar (used by Library) — dark label on cream, accent
      // indicator.
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.55),
        indicatorColor: seed,
        dividerColor: Colors.transparent,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => seed.withValues(alpha: 0.08),
        ),
      ),
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
