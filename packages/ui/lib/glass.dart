import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Three intensity levels — slice 7 §7. Maps to blur radii
/// `14 / 24 / 40` and saturation `1.2 / 1.4 / 1.8`.
enum GlassIntensity { light, medium, heavy }

/// Frosted-pane primitive: backdrop blur + saturation boost,
/// rounded corners, inset 1 px stroke, soft drop shadow. Optional
/// album-derived [tint] tints the inner gradient.
///
/// Slice 7 §10 risk 6: on the Linux software renderer
/// `BackdropFilter` is prohibitively slow because there is no
/// GPU-accelerated blur. [Glass] runtime-checks
/// `defaultTargetPlatform == TargetPlatform.linux && !kIsWeb`
/// and on the fallback path renders an opaque 0.92-alpha fill —
/// the border, shadow, and tint are preserved so the surface
/// still reads as "frosted" even though the blur is absent.
@immutable
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.intensity = GlassIntensity.medium,
    this.radius = 16,
    this.padding,
    this.tint,
  });

  final Widget child;
  final GlassIntensity intensity;
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// Album-derived dominant when present; null = neutral surface.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final blur = switch (intensity) {
      GlassIntensity.light => 14.0,
      GlassIntensity.medium => 24.0,
      GlassIntensity.heavy => 40.0,
    };
    final saturate = switch (intensity) {
      GlassIntensity.light => 1.2,
      GlassIntensity.medium => 1.4,
      GlassIntensity.heavy => 1.8,
    };

    final isLinuxDesktop =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

    final inner = Container(
      decoration: _glassDecoration(opaque: isLinuxDesktop, tint: tint),
      padding: padding,
      child: child,
    );

    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: isLinuxDesktop
          ? inner
          : BackdropFilter(
              filter: ui.ImageFilter.compose(
                outer: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                inner: ui.ColorFilter.matrix(_saturateMatrix(saturate)),
              ),
              child: inner,
            ),
    );

    // Soft drop shadow lives outside the ClipRRect so it isn't
    // clipped by the glass radius.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: clipped,
    );
  }

  /// Inner gradient + 1 px inset stroke. When `opaque` is true
  /// (Linux desktop fallback), the gradient bumps to a higher base
  /// alpha so the surface still hides what's behind it without the
  /// blur to do that work.
  ///
  /// Wireframe match: the cream paper aurora interior shows white
  /// glass with a high-saturation white border — see
  /// `wireframe/Prism Music Player (Standalone).html` rendered.
  BoxDecoration _glassDecoration({required bool opaque, Color? tint}) {
    final tintColor = tint ?? Colors.white;
    final topAlpha = opaque ? 0.92 : 0.45;
    final bottomAlpha = opaque ? 0.84 : 0.25;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color.lerp(Colors.white, tintColor, 0.12)!.withValues(
            alpha: topAlpha,
          ),
          Color.lerp(Colors.white, tintColor, 0.08)!.withValues(
            alpha: bottomAlpha,
          ),
        ],
      ),
      // 1 px inset stroke from the JSX reference.
      border: Border.all(
        color: Colors.white.withValues(alpha: 0.55),
        width: 1,
      ),
    );
  }

  /// 4×5 ColorMatrix that scales chroma. Standard saturation
  /// formula:
  ///
  ///   row_r = [lr*(1-s) + s, lg*(1-s),     lb*(1-s),     0, 0]
  ///   row_g = [lr*(1-s),     lg*(1-s) + s, lb*(1-s),     0, 0]
  ///   row_b = [lr*(1-s),     lg*(1-s),     lb*(1-s) + s, 0, 0]
  ///   row_a = [0,            0,            0,            1, 0]
  ///
  /// `lr/lg/lb` are the Rec. 709 luma coefficients. `s = 1.0`
  /// reduces to identity; `s > 1.0` boosts chroma.
  static List<double> _saturateMatrix(double s) {
    const lr = 0.2126;
    const lg = 0.7152;
    const lb = 0.0722;
    return <double>[
      lr * (1 - s) + s, lg * (1 - s),     lb * (1 - s),     0, 0,
      lr * (1 - s),     lg * (1 - s) + s, lb * (1 - s),     0, 0,
      lr * (1 - s),     lg * (1 - s),     lb * (1 - s) + s, 0, 0,
      0,                0,                0,                1, 0,
    ];
  }
}
