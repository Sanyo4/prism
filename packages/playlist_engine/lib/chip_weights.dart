import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'radio_session.dart';
import 'repo.dart';
import 'steer_chip.dart';

/// Per-chip kernels per slice 5 §8 step 5. Each kernel is a pure
/// function `(seed, candidate) → double` returning a multiplicative
/// factor near 1.0 (1.0 == neutral; >1 favours, <1 disfavours).
///
/// Aggregation rule:
/// `chipWeight = Π_active (1 + state.weight · (kernel − 1))`
/// — at `state.weight = 1` the kernel applies in full; at
/// `state.weight = 0` the kernel is the identity (1.0); intermediate
/// weights linearly fade the effect. Slice 5 ships the default
/// constants below; tuning later slices can subclass and pass to
/// `RadioEngine`.
@immutable
class ChipWeights {
  /// Mood swing strength for `happier` / `sadder`.
  final double moodHappinessGain;

  /// Calmer / more-intense gain.
  final double calmIntensityGain;

  /// BPM-delta normalization for `slower`/`faster`. Higher = wider
  /// "fast enough" zone before the kernel saturates.
  final double bpmHalfRange;

  /// Cap on `slower`/`faster` deviation from neutral.
  final double bpmKernelClamp;

  /// Year half-life for the `newer` / `older` sigmoid.
  final double yearHalfLife;

  /// Multipliers for `moreLikeThisArtist` (`onMatch` rewards same
  /// artist; `onMiss` lightly penalises strangers).
  final double sameArtistOnMatch;
  final double sameArtistOnMiss;

  /// Multipliers for `differentArtists` (`onSeen` penalises an
  /// artist already in history; `onUnseen` rewards strangers).
  final double diffArtistOnSeen;
  final double diffArtistOnUnseen;

  const ChipWeights({
    this.moodHappinessGain = 0.6,
    this.calmIntensityGain = 0.8,
    this.bpmHalfRange = 60.0,
    this.bpmKernelClamp = 0.5,
    this.yearHalfLife = 15.0,
    this.sameArtistOnMatch = 1.5,
    this.sameArtistOnMiss = 0.9,
    this.diffArtistOnSeen = 0.6,
    this.diffArtistOnUnseen = 1.1,
  });

  /// Aggregate multiplier across every active chip in [session]'s
  /// chip map. Inactive chips (`ticksRemaining = 0`) contribute 1.0.
  ///
  /// [seedMeta] is null when the seed is an album / artist mean
  /// embedding — in that case mood-anchored kernels (`happier`,
  /// `sadder`) fall back to absolute polarity instead of "more
  /// happy than seed".
  double apply(
    RadioSession session,
    CandidateMeta candidate, {
    CandidateMeta? seedMeta,
  }) {
    var product = 1.0;
    session.chips.forEach((chip, state) {
      if (!state.isActive) return;
      final raw = _kernel(chip, candidate, session, seedMeta);
      // Linear fade from 1.0 (neutral) at state.weight=0 to `raw` at
      // state.weight=1.
      final scaled = 1.0 + state.weight * (raw - 1.0);
      product *= scaled;
    });
    return product;
  }

  double _kernel(
    SteerChip chip,
    CandidateMeta c,
    RadioSession session,
    CandidateMeta? seed,
  ) {
    switch (chip) {
      case SteerChip.happier:
        return 1.0 + moodHappinessGain * (c.moodHappy - c.moodSad);
      case SteerChip.sadder:
        return 1.0 + moodHappinessGain * (c.moodSad - c.moodHappy);
      case SteerChip.calmer:
        return 1.0 +
            calmIntensityGain * (c.moodRelaxed * (1 - c.moodAggressive) - 0.5);
      case SteerChip.moreIntense:
        // Mirror on (aggressive + party) / 2 — captures both classifier
        // variants of "energy".
        return 1.0 +
            calmIntensityGain * (((c.moodAggressive + c.moodParty) / 2) - 0.5);
      case SteerChip.slower:
        if (seed == null) {
          // Without a seed BPM anchor, slower vs faster reduces to
          // a ~110 BPM bias point — a reasonable mid-tempo anchor
          // for unknown-seed (album/artist mean) sessions.
          final delta = (110.0 - c.bpm) / bpmHalfRange;
          return 1.0 + delta.clamp(-bpmKernelClamp, bpmKernelClamp);
        }
        final delta = (seed.bpm - c.bpm) / bpmHalfRange;
        return 1.0 + delta.clamp(-bpmKernelClamp, bpmKernelClamp);
      case SteerChip.faster:
        if (seed == null) {
          final delta = (c.bpm - 110.0) / bpmHalfRange;
          return 1.0 + delta.clamp(-bpmKernelClamp, bpmKernelClamp);
        }
        final delta = (c.bpm - seed.bpm) / bpmHalfRange;
        return 1.0 + delta.clamp(-bpmKernelClamp, bpmKernelClamp);
      case SteerChip.newer:
        if (c.year == null || seed?.year == null) return 1.0;
        return _sigmoid((c.year! - seed!.year!) / yearHalfLife);
      case SteerChip.older:
        if (c.year == null || seed?.year == null) return 1.0;
        return _sigmoid((seed!.year! - c.year!) / yearHalfLife);
      case SteerChip.moreLikeThisArtist:
        if (seed == null) return 1.0;
        return c.artistKey == seed.artistKey
            ? sameArtistOnMatch
            : sameArtistOnMiss;
      case SteerChip.differentArtists:
        return _historyHasArtist(session, c.artistKey)
            ? diffArtistOnSeen
            : diffArtistOnUnseen;
    }
  }

  static bool _historyHasArtist(RadioSession session, String artistKey) {
    return session.lastPickArtistKey == artistKey;
  }

  /// 0.5..1.5 sigmoid centred at 0 — at x=0 returns 1.0, at large
  /// positive x saturates near 1.5, at large negative near 0.5. We
  /// stretch the standard logistic so the chip never multiplies by
  /// zero (which would lock out a candidate that flow-scoring would
  /// otherwise allow).
  static double _sigmoid(double x) {
    final s = 1.0 / (1.0 + math.exp(-x));
    return 0.5 + s; // [0.5, 1.5]
  }
}
