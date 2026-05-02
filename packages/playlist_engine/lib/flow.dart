import 'package:meta/meta.dart';

import 'camelot.dart';
import 'radio_session.dart';
import 'repo.dart';
import 'steer_chip.dart';

/// Hard-rule + soft-bonus scorer for radio + (slice 6) playlist
/// engines. Pure: holds no state of its own; reads everything from
/// the session + candidate meta passed in.
///
/// Slice-6 reuse pact: the public API of this class — and
/// `Camelot.parse` / `Camelot.distance` — must not move. The
/// `flow_test.dart` smoke test imports from `package:prism_playlist_engine/
/// flow.dart` and `package:prism_playlist_engine/camelot.dart` directly
/// to lock this surface down.
@immutable
class FlowScorer {
  /// How many recent picks the same-artist window covers (§8 step 6).
  /// Default 3 means "no two adjacent picks share an artist, plus one
  /// pick of buffer between artist re-appearances."
  final int sameArtistWindow;

  /// History de-dup window. A candidate whose id is in the last
  /// `historyWindow` history entries is rejected outright. Per
  /// §10 risk 5 this scales up by `skipWeights` — the effective
  /// window is `min(historyWindow * skipWeight, historyWindowMax)`.
  final int historyWindow;
  final int historyWindowMax;

  /// |ΔBPM| threshold without `moreIntense`.
  final double bpmWindow;

  /// |ΔBPM| threshold with `moreIntense` active.
  final double bpmWindowIntense;

  /// Multiplicative bonus when `Camelot.distance ≤ 1`.
  final double camelotBonusAt1;

  /// Multiplicative penalty when `Camelot.distance ≥ 3`.
  final double camelotPenaltyAt3;

  const FlowScorer({
    this.sameArtistWindow = 3,
    this.historyWindow = 20,
    this.historyWindowMax = 80,
    this.bpmWindow = 15.0,
    this.bpmWindowIntense = 25.0,
    this.camelotBonusAt1 = 1.15,
    this.camelotPenaltyAt3 = 0.85,
  });

  /// Returns `null` if [candidate] should be hard-rejected; otherwise
  /// returns a multiplicative flow bonus to fold into the final pick
  /// score.
  ///
  /// Hard rejects (any one suffices):
  /// - Candidate id is in the recent history window (scaled by
  ///   skip weight, capped at [historyWindowMax]).
  /// - Candidate's artist appears in every one of the last
  ///   [sameArtistWindow] picks AND `moreLikeThisArtist` is not
  ///   active.
  /// - |Δbpm| against [previous] exceeds `bpmWindow`
  ///   (or `bpmWindowIntense` when `moreIntense` is active).
  ///
  /// Soft bonus: Camelot distance ≤ 1 multiplies the score by
  /// [camelotBonusAt1]; distance ≥ 3 by [camelotPenaltyAt3];
  /// distance == 2 (or unparseable keys on either side) is a no-op
  /// (1.0).
  double? scoreOrReject({
    required CandidateMeta candidate,
    required CandidateMeta? previous,
    required RadioSession session,
    required Map<int, CandidateMeta> historyMeta,
  }) {
    // (a) history de-dup, scaled by skip weight.
    final skip = session.skipWeights[candidate.trackId] ?? 0;
    final effectiveWindow = (historyWindow * (1 + skip)).clamp(
      historyWindow,
      historyWindowMax,
    );
    final historyTail = session.history.length <= effectiveWindow
        ? session.history
        : session.history.sublist(session.history.length - effectiveWindow);
    if (historyTail.contains(candidate.trackId)) return null;

    // (b) same-artist window. Reject only when the candidate's
    // artist would be the artist of every one of the last N picks
    // — anything less restrictive is too easy to satisfy on prolific
    // artists.
    final allowSameArtist =
        session.chips[SteerChip.moreLikeThisArtist]?.isActive ?? false;
    if (!allowSameArtist) {
      final n = sameArtistWindow;
      if (session.history.length >= n) {
        final lastN = session.history.sublist(session.history.length - n);
        var allMatch = true;
        for (final id in lastN) {
          final m = historyMeta[id];
          if (m == null || m.artistKey != candidate.artistKey) {
            allMatch = false;
            break;
          }
        }
        if (allMatch) return null;
      }
    }

    // (c) BPM window against the previous pick (or seed-equivalent).
    if (previous != null && previous.bpm > 0 && candidate.bpm > 0) {
      final bpmIntense =
          session.chips[SteerChip.moreIntense]?.isActive ?? false;
      final window = bpmIntense ? bpmWindowIntense : bpmWindow;
      // Allow half/double-time leniency — many DJ-style flows live
      // here (§ slice spec ¶5). 60↔120 should pass even with the
      // 15 BPM window.
      final delta = (candidate.bpm - previous.bpm).abs();
      final halfDouble =
          (candidate.bpm - 2 * previous.bpm).abs() < window ||
              (candidate.bpm - previous.bpm / 2).abs() < window;
      if (delta > window && !halfDouble) return null;
    }

    // Soft Camelot bonus.
    final prevKey = previous == null ? null : Camelot.parse(previous.key);
    final candKey = Camelot.parse(candidate.key);
    if (prevKey == null || candKey == null) {
      return 1.0;
    }
    return Camelot.compatibilityBonus(
      prevKey,
      candKey,
      bonusAt1: camelotBonusAt1,
      penaltyAt3: camelotPenaltyAt3,
    );
  }
}
