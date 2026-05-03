/// `PlaylistResult` — slice 6's return type from
/// `PlaylistEngine.generate`. Shape contract documented in
/// `docs/notes/slice-06-doc-refresh.md` (spec deviation §);
/// summary: the spec sketch carried `List` of `Track` from
/// `prism_core`. `packages/playlist_engine` cannot import
/// `prism_core` (slice-5 §6 hard rule), so we expose
/// `trackIds` (`List` of `int`) plus the matching `candidates`
/// (`List` of `CandidateMeta`) so the UI's result card can render
/// rows without a second repo round-trip. The mobile app
/// materialises `int -> Track` via `trackByIdLookupProvider`.
library;

import 'package:meta/meta.dart';

import 'final_pass.dart';
import 'intent.dart';
import 'repo.dart';

/// Per-run instrumentation for `PlaylistEngine.generate`. Kept
/// separate from the user-facing fields so debug rendering can
/// hide them while tests still assert against them.
@immutable
class PlaylistDebug {
  /// How many times the intent-pass repair preamble fired (0..2).
  /// Engine then falls back to `Intent.fallback`; the fallback is
  /// recorded in [usedFallback].
  final int repairCount;

  /// True when the engine fell through to `Intent.fallback(vibe)`
  /// after repair budget was exhausted (or the input was empty).
  final bool usedFallback;

  /// Final relaxation level the candidate pool needed.
  final RelaxationLevel relaxationLevel;

  /// Swaps the LLM proposed but the engine had to drop (insertId
  /// not in top-40, or dropIndex out of range).
  final List<Swap> invalidSwaps;

  /// Wall-clock duration of the LLM intent pass.
  final Duration intentMs;

  /// Wall-clock duration of the LLM narrative pass. `Duration.zero`
  /// when the narrative pass was skipped (e.g. backend repeatedly
  /// failed and engine emitted a default blurb).
  final Duration narrativeMs;

  /// Wall-clock duration of the deterministic flow step.
  final Duration flowMs;

  /// Size of the SQL-filtered candidate pool actually used.
  final int poolSize;

  /// Size of the centroid-ranked top set (≤ rankedTop).
  final int rankedSize;

  /// Size of the flow-ordered list (≤ flowedTop).
  final int flowedSize;

  const PlaylistDebug({
    required this.repairCount,
    required this.usedFallback,
    required this.relaxationLevel,
    required this.invalidSwaps,
    required this.intentMs,
    required this.narrativeMs,
    required this.flowMs,
    required this.poolSize,
    required this.rankedSize,
    required this.flowedSize,
  });

  @override
  String toString() => 'PlaylistDebug(repair: $repairCount, '
      'fallback: $usedFallback, relax: ${relaxationLevel.name}, '
      'pool: $poolSize, ranked: $rankedSize, flowed: $flowedSize, '
      'intent: ${intentMs.inMilliseconds}ms, '
      'narrate: ${narrativeMs.inMilliseconds}ms, '
      'flow: ${flowMs.inMilliseconds}ms, '
      'invalidSwaps: ${invalidSwaps.length})';
}

/// Successful output of `PlaylistEngine.generate`. Length == the
/// requested `length` (default 12). The `intent` field is the
/// (possibly fallback) intent the pipeline actually consumed —
/// useful for rendering a "we interpreted that as ..." chip in
/// the UI.
@immutable
class PlaylistResult {
  /// Track ids in playback order. Length == `length` (default 12).
  /// UI maps int → Track via slice-1's `trackByIdLookupProvider`.
  final List<int> trackIds;

  /// Per-track engine metadata in the same order as [trackIds].
  /// Lets the result card render rows (title, artist, bpm, key)
  /// without a repo round-trip.
  final List<CandidateMeta> candidates;

  /// LLM's blurb (already trimmed to ≤ 2 sentences / 240 chars).
  /// On exhausted repair budget the engine emits a default blurb
  /// derived from `intent.narrative`.
  final String blurb;

  /// The intent the engine actually used (may be a fallback).
  final Intent intent;

  /// Per-run timing + repair instrumentation.
  final PlaylistDebug debug;

  const PlaylistResult({
    required this.trackIds,
    required this.candidates,
    required this.blurb,
    required this.intent,
    required this.debug,
  });

  @override
  String toString() => 'PlaylistResult(${trackIds.length} tracks, '
      'blurb: ${blurb.length} chars)';
}
