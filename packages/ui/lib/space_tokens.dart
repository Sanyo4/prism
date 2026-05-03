import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Non-linear spacing scale, Material-like, baked at the
/// `ThemeExtension` layer so every Prism widget reads its
/// gaps from the same source instead of from inline literals.
///
/// Values (slice 7 §7): `4, 8, 12, 16, 24, 32, 48`. Slice 7 ships
/// only the mobile profile; the `lerp` is implemented for forward
/// compatibility with a desktop-density round in slice 7-polish v2.
///
/// Convention: `s4 == 16` is the base "card padding" gap; everything
/// else nudges off that. Track B's token sweep replaces every
/// `EdgeInsets.all(16)` etc. with reads against this scale.
@immutable
class SpaceTokens extends ThemeExtension<SpaceTokens> {
  const SpaceTokens({
    required this.s1,
    required this.s2,
    required this.s3,
    required this.s4,
    required this.s6,
    required this.s8,
    required this.s12,
  });

  /// Mobile / default density. Locked sequence `{4, 8, 12, 16, 24, 32, 48}`.
  const SpaceTokens.mobile()
    : s1 = 4,
      s2 = 8,
      s3 = 12,
      s4 = 16,
      s6 = 24,
      s8 = 32,
      s12 = 48;

  /// 4 px — hair-line gap (chip-internal padding, icon-to-label
  /// adjacency).
  final double s1;

  /// 8 px — small inline gap (between adjacent chips, between an
  /// avatar and a label, between two stacked metadata lines).
  final double s2;

  /// 12 px — list-row vertical padding, thumbnail-to-text gap.
  final double s3;

  /// 16 px — base "card padding" / section gap. Default `EdgeInsets`.
  final double s4;

  /// 24 px — between two distinct UI sections (row → row).
  final double s6;

  /// 32 px — top-of-screen gap, hero header padding.
  final double s8;

  /// 48 px — full-bleed section break (album art breathing room).
  final double s12;

  @override
  SpaceTokens copyWith({
    double? s1,
    double? s2,
    double? s3,
    double? s4,
    double? s6,
    double? s8,
    double? s12,
  }) {
    return SpaceTokens(
      s1: s1 ?? this.s1,
      s2: s2 ?? this.s2,
      s3: s3 ?? this.s3,
      s4: s4 ?? this.s4,
      s6: s6 ?? this.s6,
      s8: s8 ?? this.s8,
      s12: s12 ?? this.s12,
    );
  }

  @override
  SpaceTokens lerp(covariant ThemeExtension<SpaceTokens>? other, double t) {
    // Identity fast-path: when `other` is `null` or not the same
    // type, don't try to interpolate. When all fields match the
    // result of `lerpDouble` is identical to either side anyway —
    // and slice 7 only ships one profile — but the channel-wise
    // form is here for forward-compat with a desktop-density
    // variant in a later round.
    if (other is! SpaceTokens) return this;
    return SpaceTokens(
      s1: lerpDouble(s1, other.s1, t)!,
      s2: lerpDouble(s2, other.s2, t)!,
      s3: lerpDouble(s3, other.s3, t)!,
      s4: lerpDouble(s4, other.s4, t)!,
      s6: lerpDouble(s6, other.s6, t)!,
      s8: lerpDouble(s8, other.s8, t)!,
      s12: lerpDouble(s12, other.s12, t)!,
    );
  }
}
