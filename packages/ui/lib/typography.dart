import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Five-step typography scale for Prism — display 36 / 28 / 20,
/// body 16, caption 13.
///
/// Slice 7 §2 / §7: line-heights `1.15` on the three displays and
/// `1.45` on body + caption. Letter-spacing `−0.4 / −0.2 / 0 / 0 /
/// 0.1`. **Font: Space Grotesk** — matches the design bundle
/// (`/tmp/prism-design-extract/music/project/ui/primitives.jsx`),
/// which uses `"Space Grotesk", system-ui, sans-serif` everywhere.
/// The slice-7 plan §2 originally listed `SF Pro Display → Inter →
/// Geist`; we deviate to match the design. Space Grotesk is an
/// OFL-licensed Google Font, fetched + cached via `google_fonts` on
/// first launch, served from the device cache thereafter.
///
/// The cache trade-off: first launch on a fresh install needs
/// network for ~120 KB per weight. Subsequent launches are offline.
/// True offline-from-cold-install gets the platform default sans
/// (Roboto on Android, Cantarell on GNOME), which is acceptable for
/// the slice-7 verification matrix. Slice 8 can bundle the TTF
/// binaries under `apps/mobile/assets/fonts/` for guaranteed offline
/// rendering on the phone.
///
/// `toMaterialTextTheme()` plugs the five named styles into the
/// Material 3 `TextTheme` slots Prism actually uses; the ten other
/// slots are filled with sensible derivations so the rare widget
/// that reads them does not face nulls.
@immutable
class TypographyScale extends ThemeExtension<TypographyScale> {
  const TypographyScale({
    required this.display36,
    required this.display28,
    required this.display20,
    required this.body16,
    required this.caption13,
  });

  /// 36 px / 1.15 / -0.4 / w700. Hero album titles, "Now Playing"
  /// expanded title.
  final TextStyle display36;

  /// 28 px / 1.15 / -0.2 / w700. Album-detail header, "Library"
  /// section titles.
  final TextStyle display28;

  /// 20 px / 1.15 / 0 / w600. Card headers, MiniPlayer title.
  final TextStyle display20;

  /// 16 px / 1.45 / 0 / w400. Body copy.
  final TextStyle body16;

  /// 13 px / 1.45 / 0.1 / w400. Track-row metadata, captions, chips.
  final TextStyle caption13;

  /// Build the Prism scale, using `GoogleFonts.spaceGrotesk` for
  /// the family. `google_fonts` fetches the TTF on first launch and
  /// caches it locally; subsequent launches resolve from the cache.
  ///
  /// On a truly cold install with no network, `google_fonts` falls
  /// back to the platform default sans — the user sees Roboto on
  /// Android / Cantarell on GNOME until the cache populates. This
  /// trade-off matches the design source's `system-ui, sans-serif`
  /// fallback chain.
  ///
  /// Tests that exercise this factory must use [testFixture] instead
  /// — `GoogleFonts.spaceGrotesk()` schedules an async asset-bundle
  /// + HTTP probe that throws an unhandled exception under
  /// `flutter test`'s no-network sandbox.
  factory TypographyScale.prism() {
    return TypographyScale(
      display36: GoogleFonts.spaceGrotesk(
        fontSize: 36,
        height: 1.15,
        letterSpacing: -0.4,
        fontWeight: FontWeight.w700,
      ),
      display28: GoogleFonts.spaceGrotesk(
        fontSize: 28,
        height: 1.15,
        letterSpacing: -0.2,
        fontWeight: FontWeight.w700,
      ),
      display20: GoogleFonts.spaceGrotesk(
        fontSize: 20,
        height: 1.15,
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
      ),
      body16: GoogleFonts.spaceGrotesk(
        fontSize: 16,
        height: 1.45,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
      ),
      caption13: GoogleFonts.spaceGrotesk(
        fontSize: 13,
        height: 1.45,
        letterSpacing: 0.1,
        fontWeight: FontWeight.w400,
      ),
    );
  }

  /// Test-only factory that bypasses `google_fonts`. Produces the
  /// same five `TextStyle` shapes (sizes, heights, letter-spacing,
  /// weights) as [prism] but with `fontFamily: 'Space Grotesk'` set
  /// as a plain string instead of going through `google_fonts`'
  /// asset-bundle + HTTP probe. Tests that call this never hit the
  /// no-network async exception that made the production factory
  /// unusable in the test sandbox.
  ///
  /// Production callers must use [prism]; only tests should reach
  /// for this. Visually identical when the app is allowed to fetch
  /// the cached Space Grotesk asset.
  @visibleForTesting
  factory TypographyScale.testFixture() {
    const family = 'Space Grotesk';
    TextStyle display(double size, double letterSpacing, FontWeight weight) =>
        TextStyle(
          fontFamily: family,
          fontSize: size,
          height: 1.15,
          letterSpacing: letterSpacing,
          fontWeight: weight,
        );
    TextStyle text(double size, double letterSpacing, FontWeight weight) =>
        TextStyle(
          fontFamily: family,
          fontSize: size,
          height: 1.45,
          letterSpacing: letterSpacing,
          fontWeight: weight,
        );
    return TypographyScale(
      display36: display(36, -0.4, FontWeight.w700),
      display28: display(28, -0.2, FontWeight.w700),
      display20: display(20, 0, FontWeight.w600),
      body16: text(16, 0, FontWeight.w400),
      caption13: text(13, 0.1, FontWeight.w400),
    );
  }

  /// Fold the five named styles into a Material 3 [TextTheme].
  ///
  /// Mapping (slice 7 §8 step 3):
  /// - `displayLarge`  ← display36
  /// - `displayMedium` ← display28
  /// - `headlineLarge` ← display28 (sensible derivation)
  /// - `headlineMedium`← display20
  /// - `titleLarge`    ← display20
  /// - `titleMedium`   ← body16 with w600 (derived)
  /// - `titleSmall`    ← body16 with w500 (derived)
  /// - `bodyLarge`     ← body16
  /// - `bodyMedium`    ← body16
  /// - `bodySmall`     ← caption13
  /// - `labelLarge`    ← body16 with w500 (derived)
  /// - `labelMedium`   ← caption13 with w500 (derived)
  /// - `labelSmall`    ← caption13
  TextTheme toMaterialTextTheme() {
    return TextTheme(
      displayLarge: display36,
      displayMedium: display28,
      displaySmall: display20,
      headlineLarge: display28,
      headlineMedium: display20,
      headlineSmall: display20,
      titleLarge: display20,
      titleMedium: body16.copyWith(fontWeight: FontWeight.w600),
      titleSmall: body16.copyWith(fontWeight: FontWeight.w500),
      bodyLarge: body16,
      bodyMedium: body16,
      bodySmall: caption13,
      labelLarge: body16.copyWith(fontWeight: FontWeight.w500),
      labelMedium: caption13.copyWith(fontWeight: FontWeight.w500),
      labelSmall: caption13,
    );
  }

  @override
  TypographyScale copyWith({
    TextStyle? display36,
    TextStyle? display28,
    TextStyle? display20,
    TextStyle? body16,
    TextStyle? caption13,
  }) {
    return TypographyScale(
      display36: display36 ?? this.display36,
      display28: display28 ?? this.display28,
      display20: display20 ?? this.display20,
      body16: body16 ?? this.body16,
      caption13: caption13 ?? this.caption13,
    );
  }

  @override
  TypographyScale lerp(
    covariant ThemeExtension<TypographyScale>? other,
    double t,
  ) {
    if (other is! TypographyScale) return this;
    return TypographyScale(
      display36: TextStyle.lerp(display36, other.display36, t)!,
      display28: TextStyle.lerp(display28, other.display28, t)!,
      display20: TextStyle.lerp(display20, other.display20, t)!,
      body16: TextStyle.lerp(body16, other.body16, t)!,
      caption13: TextStyle.lerp(caption13, other.caption13, t)!,
    );
  }
}
