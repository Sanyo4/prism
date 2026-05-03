import 'package:flutter/material.dart';

/// One per top-level screen — picks the base radial gradient and
/// the blob set that go behind the route's content.
///
/// Slice 7 §7: `home`, `album`, `player`, `library`, `ai`. Only
/// `album` and `player` honor [AuroraBackground.accentOverride];
/// the other three ignore it and use their preset accent (which
/// matches one of the five locked preset colors from `palette.dart`).
enum AuroraVariant { home, album, player, library, ai }

/// Static, blurred, grain-overlaid backdrop. Five variants share
/// the same composition stack:
///   1. base radial gradient (variant-specific stops + center),
///   2. 2-3 large soft-edged colored blobs at fixed positions,
///   3. shared monochrome grain overlay at 0.04 opacity.
///
/// Slice 7 §2 forbids motion: nothing in [AuroraBackground]
/// animates. The grain `AssetImage` is loaded once and cached by
/// Flutter's image cache (slice 7 §10 risk 10).
///
/// `accentOverride`: when present and the variant honors overrides
/// (`album` or `player`), the primary blob hue and the right-hand
/// stop of the base gradient are swapped to that color. The other
/// blob hues stay on the variant's preset.
@immutable
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({
    super.key,
    required this.variant,
    required this.child,
    this.accentOverride,
  });

  final AuroraVariant variant;

  /// When non-null and [variant] is `album` or `player`, this color
  /// becomes the primary blob hue and the right-hand stop of the
  /// base gradient. Ignored for `home`, `library`, and `ai`.
  final Color? accentOverride;

  final Widget child;

  bool get _honorsOverride =>
      variant == AuroraVariant.album || variant == AuroraVariant.player;

  @override
  Widget build(BuildContext context) {
    final spec = _kVariantSpecs[variant]!;
    final accent = (_honorsOverride && accentOverride != null)
        ? accentOverride!
        : spec.primaryAccent;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Base radial gradient — variant-specific center, stops
        //    are blended against `accent` so an accent-override
        //    shifts the right-hand stop too.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: spec.gradientCenter,
              radius: spec.gradientRadius,
              colors: <Color>[
                spec.baseStartColor,
                Color.lerp(spec.baseEndColor, accent, 0.35)!,
              ],
              stops: const <double>[0.0, 1.0],
            ),
          ),
        ),
        // 2. Static blobs.
        for (final blob in spec.blobs)
          Positioned(
            left: blob.left,
            top: blob.top,
            right: blob.right,
            bottom: blob.bottom,
            child: IgnorePointer(
              child: Container(
                width: blob.size,
                height: blob.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      (blob.usesAccent ? accent : blob.color)
                          .withValues(alpha: blob.alpha),
                      (blob.usesAccent ? accent : blob.color)
                          .withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // 3. Shared grain overlay — single AssetImage cached by
        //    Flutter's image cache (slice 7 §10 risk 10).
        const Positioned.fill(
          child: IgnorePointer(
            child: Image(
              image: AssetImage(
                'assets/grain.png',
                package: 'prism_ui',
              ),
              fit: BoxFit.cover,
              repeat: ImageRepeat.repeat,
              opacity: AlwaysStoppedAnimation<double>(0.04),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Static spec for one [AuroraVariant]. All numeric values are
/// resolution-independent (alignments, fractions of available
/// space) so the same spec works on phone, fold-outer, and
/// desktop.
@immutable
class _VariantSpec {
  const _VariantSpec({
    required this.primaryAccent,
    required this.baseStartColor,
    required this.baseEndColor,
    required this.gradientCenter,
    required this.gradientRadius,
    required this.blobs,
  });

  /// Default accent — matches one of the five preset accents from
  /// `palette.dart`. Used when [AuroraBackground.accentOverride] is
  /// null or the variant does not honor it.
  final Color primaryAccent;

  /// Inner color of the base radial gradient.
  final Color baseStartColor;

  /// Outer color of the base radial gradient (gets lerped 35%
  /// toward the accent at runtime).
  final Color baseEndColor;

  final Alignment gradientCenter;
  final double gradientRadius;

  final List<_BlobSpec> blobs;
}

@immutable
class _BlobSpec {
  const _BlobSpec({
    required this.size,
    required this.color,
    this.alpha = 0.45,
    this.usesAccent = false,
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  /// Diameter, in logical px.
  final double size;

  /// Color when `usesAccent` is false.
  final Color color;

  /// Inner alpha; the radial gradient fades to 0 at the edge.
  final double alpha;

  /// When true, [color] is ignored and the `AuroraBackground`
  /// substitutes either `accentOverride` (if set + variant honors
  /// overrides) or the variant's `primaryAccent`.
  final bool usesAccent;

  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
}

// Five preset accents — these match the locked values from
// `palette.dart`'s `kPresetAccents`. Repeating them as private
// constants keeps `aurora_background.dart` from importing
// `palette.dart` (smaller, more focused module).
const Color _kBlue = Color(0xFF6BA8FF);
const Color _kPink = Color(0xFFFFA0C8);
const Color _kMint = Color(0xFFA0E8C4);
const Color _kAmber = Color(0xFFFFC878);
const Color _kLilac = Color(0xFFC0A0FF);

// Soft off-white "paper" tone used as the inner base gradient
// across all five variants. Keeps the surface readable.
const Color _kPaper = Color(0xFFFBF7F2);

const Map<AuroraVariant, _VariantSpec> _kVariantSpecs = <AuroraVariant,
    _VariantSpec>{
  AuroraVariant.home: _VariantSpec(
    primaryAccent: _kBlue,
    baseStartColor: _kPaper,
    baseEndColor: Color(0xFFEAF2FF),
    gradientCenter: Alignment(-0.4, -0.6),
    gradientRadius: 1.4,
    blobs: <_BlobSpec>[
      _BlobSpec(
        size: 360,
        color: _kBlue,
        alpha: 0.40,
        left: -80,
        top: -120,
      ),
      _BlobSpec(
        size: 320,
        color: _kPink,
        alpha: 0.30,
        right: -60,
        top: 80,
      ),
      _BlobSpec(
        size: 280,
        color: _kMint,
        alpha: 0.28,
        left: 40,
        bottom: -100,
      ),
    ],
  ),
  AuroraVariant.album: _VariantSpec(
    primaryAccent: _kPink,
    baseStartColor: _kPaper,
    baseEndColor: Color(0xFFFFEEF5),
    gradientCenter: Alignment(0.0, -0.4),
    gradientRadius: 1.5,
    blobs: <_BlobSpec>[
      _BlobSpec(
        size: 420,
        color: _kPink,
        alpha: 0.45,
        usesAccent: true,
        left: -100,
        top: -160,
      ),
      _BlobSpec(
        size: 320,
        color: _kAmber,
        alpha: 0.30,
        right: -80,
        bottom: -100,
      ),
    ],
  ),
  AuroraVariant.player: _VariantSpec(
    primaryAccent: _kBlue,
    baseStartColor: _kPaper,
    baseEndColor: Color(0xFFEFEEFB),
    gradientCenter: Alignment(0.0, 0.2),
    gradientRadius: 1.6,
    blobs: <_BlobSpec>[
      _BlobSpec(
        size: 480,
        color: _kBlue,
        alpha: 0.50,
        usesAccent: true,
        left: -120,
        top: -180,
      ),
      _BlobSpec(
        size: 360,
        color: _kLilac,
        alpha: 0.35,
        right: -100,
        top: 60,
      ),
      _BlobSpec(
        size: 300,
        color: _kPink,
        alpha: 0.28,
        left: 40,
        bottom: -120,
      ),
    ],
  ),
  AuroraVariant.library: _VariantSpec(
    primaryAccent: _kMint,
    baseStartColor: _kPaper,
    baseEndColor: Color(0xFFEEF7F1),
    gradientCenter: Alignment(-0.2, -0.4),
    gradientRadius: 1.4,
    blobs: <_BlobSpec>[
      _BlobSpec(
        size: 320,
        color: _kMint,
        alpha: 0.38,
        left: -60,
        top: -80,
      ),
      _BlobSpec(
        size: 260,
        color: _kBlue,
        alpha: 0.22,
        right: -40,
        bottom: 40,
      ),
    ],
  ),
  AuroraVariant.ai: _VariantSpec(
    primaryAccent: _kLilac,
    baseStartColor: _kPaper,
    baseEndColor: Color(0xFFF3EDFC),
    gradientCenter: Alignment(0.2, -0.2),
    gradientRadius: 1.5,
    blobs: <_BlobSpec>[
      _BlobSpec(
        size: 400,
        color: _kLilac,
        alpha: 0.42,
        left: -80,
        top: -120,
      ),
      _BlobSpec(
        size: 320,
        color: _kPink,
        alpha: 0.30,
        right: -80,
        top: 100,
      ),
      _BlobSpec(
        size: 280,
        color: _kAmber,
        alpha: 0.24,
        left: 60,
        bottom: -80,
      ),
    ],
  ),
};
