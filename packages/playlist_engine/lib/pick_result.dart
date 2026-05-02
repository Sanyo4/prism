import 'package:meta/meta.dart';

import 'radio_session.dart';

/// Per-candidate score breakdown, kept on [PickResult.debug] for
/// instrumentation (§11 verification item 2 — "dump
/// `ScoreBreakdown.similarity` per pick").
@immutable
class ScoreBreakdown {
  /// `exp(-l2 / 0.5)` — the kNN distance mapped through the slice's
  /// τ=0.5 kernel. Higher = closer to the seed in embedding space.
  final double similarity;

  /// Aggregate steer-chip multiplier (`Π_active (1 + w·(k − 1))`).
  /// 1.0 when no chips active.
  final double chipWeight;

  /// FlowScorer's multiplicative bonus. Defaults to 1.0 when no
  /// previous pick / no Camelot signal.
  final double flowBonus;

  /// Final picking score = similarity · chipWeight · flowBonus.
  /// Same value `RadioEngine.next` argmaxes over.
  final double finalScore;

  /// Whether this pick was selected from the kNN neighbourhood
  /// (`false` indicates the library-wide fallback engaged because
  /// the seed had < 50 ready neighbours — §10 risk 1).
  final bool fromKnn;

  const ScoreBreakdown({
    required this.similarity,
    required this.chipWeight,
    required this.flowBonus,
    required this.finalScore,
    required this.fromKnn,
  });
}

/// Output of one `RadioEngine.next` call: the chosen track id, the
/// updated session, and a debug breakdown for instrumentation.
@immutable
class PickResult {
  final int pickedTrackId;
  final RadioSession nextSession;
  final ScoreBreakdown debug;

  const PickResult({
    required this.pickedTrackId,
    required this.nextSession,
    required this.debug,
  });
}
