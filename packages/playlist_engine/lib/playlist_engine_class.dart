/// `PlaylistEngine` — slice-6 LLM-driven 12-track playlist pipeline.
///
/// Six steps, in order: (1) `LlmBackend.buildIntent` (with repair
/// loop), (2) `repo.candidatePoolByIntent` (with strict → loose →
/// veryLoose → libraryWide fallback), (3) centroid-cosine rank to
/// top-40, (4) `FlowScorer` greedy ordering to 20, (5)
/// `LlmBackend.refine` swap-and-blurb pass, (6) trim to `length`.
/// Reuses slice-5's `FlowScorer` and `Camelot` *verbatim*.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'final_pass.dart';
import 'flow.dart';
import 'intent.dart';
import 'llm_backend.dart';
import 'playlist_result.dart';
import 'radio_session.dart';
import 'repo.dart';
import 'steer_chip.dart';

/// Six-step pipeline. Stateless aside from configuration; one
/// instance is shared across all `generate()` calls.
///
/// `PlaylistEngine.generate` never throws on malformed LLM output —
/// it degrades gracefully:
/// - `Intent` malformed → up to 2 repair prompts → `Intent.fallback`.
/// - Pool too small → `loose` → `veryLoose` → `libraryWideFallback`.
/// - `refine` fails → default blurb derived from `intent.narrative`.
///
/// Surfaces `PlaylistCancelled` only when the backend's transport
/// was cancelled mid-flight (UI closed the sheet). Surfaces
/// `StateError` only when the entire library has zero `ready`
/// rows.
class PlaylistEngine {
  /// Slice-5's flow scorer — same defaults as `RadioEngine`.
  final FlowScorer flow;

  /// Strict-mode SQL `LIMIT`. The engine retries with `loose` and
  /// then `veryLoose` if the strict pool is below `length * 4`.
  final int poolSize;

  /// Top-N retained after centroid-cosine rank.
  final int rankedTop;

  /// Top-N retained after flow ordering. The narrative pass
  /// receives this exact count.
  final int flowedTop;

  const PlaylistEngine({
    this.flow = const FlowScorer(),
    this.poolSize = 200,
    this.rankedTop = 40,
    this.flowedTop = 20,
  });

  /// Run the pipeline against [llm] / [repo]. Returns [length]
  /// trackIds (default 12) on any non-empty library. Engine never
  /// throws on malformed LLM output; see class docs for the
  /// degradation rules.
  Future<PlaylistResult> generate({
    required String vibe,
    required LlmBackend llm,
    required TrackRepo repo,
    int length = 12,
  }) async {
    // (1) INTENT — repair loop.
    var repairCount = 0;
    var usedFallback = false;
    Intent intent;
    final intentSw = Stopwatch()..start();
    final trimmedVibe = vibe.trim();
    if (trimmedVibe.isEmpty) {
      // §10 risk 10 — empty/whitespace short-circuits to fallback.
      intent = Intent.fallback('shuffle');
      usedFallback = true;
    } else {
      final outcome = await _runIntentWithRepair(
        llm: llm,
        vibe: trimmedVibe,
        onRepair: () => repairCount += 1,
      );
      intent = outcome.intent;
      usedFallback = outcome.usedFallback;
    }
    intentSw.stop();

    // (2) POOL — relax until ≥ length, else libraryWideFallback.
    var relax = RelaxationLevel.strict;
    var pool = await repo.candidatePoolByIntent(
      intent,
      poolSize: poolSize,
      relax: relax,
    );
    if (pool.length < length * 4) {
      relax = RelaxationLevel.loose;
      pool = await repo.candidatePoolByIntent(
        intent.copyRelaxed(relax),
        poolSize: poolSize,
        relax: relax,
      );
    }
    if (pool.length < length * 2) {
      relax = RelaxationLevel.veryLoose;
      pool = await repo.candidatePoolByIntent(
        intent.copyRelaxed(relax),
        poolSize: poolSize * 2,
        relax: relax,
      );
    }
    if (pool.length < length) {
      // Final fallback: random `ready` rows.
      final fb = await repo.libraryWideFallback(limit: 100);
      // Merge — preserve any pool we have.
      final seen = <int>{...pool};
      for (final id in fb) {
        if (seen.add(id)) pool.add(id);
      }
    }
    if (pool.isEmpty) {
      throw StateError(
        'PlaylistEngine.generate: library has zero ready tracks',
      );
    }

    // (3) RANK — centroid cosine over the pool → top-rankedTop.
    final centroid = await _buildCentroid(intent, repo);
    final metas = await repo.metaOfMany(pool);
    final byId = <int, CandidateMeta>{
      for (final m in metas) m.trackId: m,
    };
    final embeddings = await _embeddingsFor(pool, repo);

    final rankings = <_RankedCandidate>[];
    for (final id in pool) {
      final meta = byId[id];
      final emb = embeddings[id];
      if (meta == null || emb == null) continue;
      final sim = _cosine(centroid, emb);
      rankings.add(_RankedCandidate(meta, emb, sim));
    }
    rankings.sort((a, b) => b.cosine.compareTo(a.cosine));
    final ranked = rankings.length <= rankedTop
        ? rankings
        : rankings.sublist(0, rankedTop);

    // (4) FLOW — greedy argmax of cosine · FlowScorer bonus.
    final flowSw = Stopwatch()..start();
    final ordered = _flowOrder(
      ranked: ranked,
      intent: intent,
      desired: math.min(flowedTop, ranked.length),
    );
    flowSw.stop();

    // (5) NARRATE — refine swap pass; on failure, default blurb.
    final narrSw = Stopwatch();
    String blurb;
    var invalidSwaps = const <Swap>[];
    if (ordered.isEmpty) {
      blurb = _defaultBlurb(intent);
    } else {
      narrSw.start();
      try {
        final fp = await llm.refine(intent, ordered);
        final applyResult = _applySwaps(
          ordered: ordered,
          fp: fp,
          ranked: ranked,
        );
        ordered
          ..clear()
          ..addAll(applyResult.ordered);
        invalidSwaps = applyResult.invalid;
        blurb = fp.blurb.isEmpty ? _defaultBlurb(intent) : fp.blurb;
      } on PlaylistCancelled {
        rethrow;
      } on Object {
        // Any narrative-pass failure → default blurb, keep ordered
        // as-is.
        blurb = _defaultBlurb(intent);
      }
      narrSw.stop();
    }

    // (6) TRIM — first `length`.
    final trimmed = ordered.length <= length
        ? ordered
        : ordered.sublist(0, length);
    if (trimmed.length < length) {
      // Pad with the next-best ranked candidates not already in the
      // ordered list. Maintains exact-length guarantee on tiny
      // libraries.
      final used = <int>{for (final m in trimmed) m.trackId};
      for (final r in ranked) {
        if (trimmed.length == length) break;
        if (!used.contains(r.meta.trackId)) {
          trimmed.add(r.meta);
          used.add(r.meta.trackId);
        }
      }
      // Still short? pull from the unsorted pool as last resort.
      if (trimmed.length < length) {
        for (final id in pool) {
          if (trimmed.length == length) break;
          if (!used.contains(id) && byId[id] != null) {
            trimmed.add(byId[id]!);
            used.add(id);
          }
        }
      }
    }

    return PlaylistResult(
      trackIds: List<int>.unmodifiable([for (final m in trimmed) m.trackId]),
      candidates: List<CandidateMeta>.unmodifiable(trimmed),
      blurb: blurb,
      intent: intent,
      debug: PlaylistDebug(
        repairCount: repairCount,
        usedFallback: usedFallback,
        relaxationLevel: relax,
        invalidSwaps: List<Swap>.unmodifiable(invalidSwaps),
        intentMs: intentSw.elapsed,
        narrativeMs: narrSw.elapsed,
        flowMs: flowSw.elapsed,
        poolSize: pool.length,
        rankedSize: ranked.length,
        flowedSize: ordered.length,
      ),
    );
  }

  // ------------------------------------------------------------------
  // (1) INTENT — repair loop.
  // ------------------------------------------------------------------

  Future<_IntentOutcome> _runIntentWithRepair({
    required LlmBackend llm,
    required String vibe,
    required void Function() onRepair,
  }) async {
    String currentPrompt = vibe;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final intent = await llm.buildIntent(currentPrompt);
        return _IntentOutcome(intent: intent, usedFallback: false);
      } on PlaylistCancelled {
        rethrow;
      } on LlmJsonParseException catch (e) {
        if (attempt < 2) {
          onRepair();
          currentPrompt = _repairPrompt(vibe, e);
        }
      } on Object {
        // Backend transport blew up on something other than a JSON
        // failure — same fallback path. Don't burn the repair budget
        // on a non-JSON error.
        break;
      }
    }
    // Repair budget exhausted (or non-recoverable error) → fallback.
    return _IntentOutcome(
      intent: Intent.fallback(vibe),
      usedFallback: true,
    );
  }

  String _repairPrompt(String vibe, LlmJsonParseException e) {
    return 'Your previous response was rejected: ${e.reason}\n'
        'Re-emit ONLY valid JSON matching the schema. '
        'Original vibe: $vibe';
  }

  // ------------------------------------------------------------------
  // (3) RANK — centroid + cosine helpers.
  // ------------------------------------------------------------------

  Future<Float32List> _buildCentroid(Intent intent, TrackRepo repo) async {
    if (intent.seedTracks.isNotEmpty) {
      final embs = <Float32List>[];
      for (final id in intent.seedTracks) {
        try {
          embs.add(await repo.embeddingOf(id));
        } catch (_) {
          // Missing seed → skip; if all skipped fall through to
          // keyword path.
        }
      }
      if (embs.isNotEmpty) {
        return _l2NormalizeMean(embs);
      }
    }
    return repo.meanEmbeddingForKeywords(intent.seedKeywords);
  }

  Future<Map<int, Float32List>> _embeddingsFor(
    List<int> ids,
    TrackRepo repo,
  ) async {
    final out = <int, Float32List>{};
    for (final id in ids) {
      try {
        out[id] = await repo.embeddingOf(id);
      } catch (_) {
        // skip
      }
    }
    return out;
  }

  static double _cosine(Float32List a, Float32List b) {
    if (a.length != b.length) return 0.0;
    var dot = 0.0;
    var na = 0.0;
    var nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    final denom = math.sqrt(na) * math.sqrt(nb);
    if (denom == 0.0) return 0.0;
    return dot / denom;
  }

  static Float32List _l2NormalizeMean(List<Float32List> sources) {
    if (sources.isEmpty) return Float32List(1280);
    final dim = sources.first.length;
    final acc = Float32List(dim);
    for (final s in sources) {
      if (s.length != dim) continue;
      for (var i = 0; i < dim; i++) {
        acc[i] += s[i];
      }
    }
    var sumSq = 0.0;
    for (var i = 0; i < dim; i++) {
      acc[i] /= sources.length;
      sumSq += acc[i] * acc[i];
    }
    final norm = math.sqrt(sumSq);
    if (norm == 0.0) return acc;
    final out = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      out[i] = acc[i] / norm;
    }
    return out;
  }

  // ------------------------------------------------------------------
  // (4) FLOW — greedy ordering with pseudo-session.
  // ------------------------------------------------------------------

  List<CandidateMeta> _flowOrder({
    required List<_RankedCandidate> ranked,
    required Intent intent,
    required int desired,
  }) {
    if (ranked.isEmpty) return <CandidateMeta>[];
    final remaining = <_RankedCandidate>[...ranked];
    final picks = <CandidateMeta>[];
    final picksRanked = <_RankedCandidate>[];

    // Pick #0: highest cosine.
    final first = remaining.removeAt(0);
    picks.add(first.meta);
    picksRanked.add(first);

    for (var i = 1; i < desired && remaining.isNotEmpty; i++) {
      final session = _pseudoSession(intent, picks, slot: i);
      final historyMeta = <int, CandidateMeta>{
        for (final p in picks) p.trackId: p,
      };
      final previous = picks.last;

      // Score every remaining candidate; track best regardless of
      // strict same-artist drop in case we need the relaxed slot.
      // Adjacent same-artist is an *engine*-level hard rule per
      // slice plan §11 item 4 (stricter than `FlowScorer`'s
      // 3-pick window) — enforced here as a pre-filter.
      _RankedCandidate? bestStrict;
      var bestStrictScore = -double.infinity;
      _RankedCandidate? bestRelaxed;
      var bestRelaxedScore = -double.infinity;
      for (final c in remaining) {
        final adjacentSameArtist = c.meta.artistKey == previous.artistKey;
        final flowBonus = flow.scoreOrReject(
          candidate: c.meta,
          previous: previous,
          session: session,
          historyMeta: historyMeta,
        );
        if (!adjacentSameArtist && flowBonus != null) {
          final score = c.cosine * flowBonus;
          if (score > bestStrictScore) {
            bestStrictScore = score;
            bestStrict = c;
          }
        }
        // Relaxed evaluation: drop the artist-window rule (engine
        // level) for this one slot — but still keep the BPM /
        // history checks via FlowScorer. Slice plan §8 step 8:
        // "If FlowScorer rejects everything remaining at slot i,
        // drop the artist-window rule for that one slot, then
        // restore." We honour this with the moreLikeThisArtist
        // chip toggle (which silences the slice-5 same-artist
        // rule) and skip the engine-level adjacency check.
        final relaxedSession = session.withChipToggled(
          SteerChip.moreLikeThisArtist,
        );
        final relaxedBonus = flow.scoreOrReject(
          candidate: c.meta,
          previous: previous,
          session: relaxedSession,
          historyMeta: historyMeta,
        );
        if (relaxedBonus != null) {
          final relaxedScore = c.cosine * relaxedBonus;
          if (relaxedScore > bestRelaxedScore) {
            bestRelaxedScore = relaxedScore;
            bestRelaxed = c;
          }
        }
      }
      // Prefer strict; fall through to relaxed only if every
      // remaining candidate violated the artist-adjacency rule.
      final pick = bestStrict ?? bestRelaxed;
      if (pick == null) break;
      picks.add(pick.meta);
      picksRanked.add(pick);
      remaining.remove(pick);
    }
    return picks;
  }

  /// Build a `RadioSession` whose chips encode [intent.energyArc].
  /// `build` → `faster`; `descend` → `slower`; `wave` → alternates
  /// per slot; `flat` → no chips.
  ///
  /// `picks` becomes the session's `history` so `FlowScorer`'s
  /// same-artist window check sees prior picks as if they were
  /// radio history.
  RadioSession _pseudoSession(
    Intent intent,
    List<CandidateMeta> picks, {
    required int slot,
  }) {
    final history = <int>[for (final p in picks) p.trackId];
    final chips = <SteerChip, ChipState>{};
    switch (intent.energyArc) {
      case EnergyArc.build:
        chips[SteerChip.faster] = const ChipState(10);
        break;
      case EnergyArc.descend:
        chips[SteerChip.slower] = const ChipState(10);
        break;
      case EnergyArc.wave:
        chips[slot.isOdd ? SteerChip.faster : SteerChip.slower] =
            const ChipState(10);
        break;
      case EnergyArc.flat:
        break;
    }
    return RadioSession(
      seed: TrackSeed(
        trackId: picks.isEmpty ? 0 : picks.first.trackId,
        title: 'pseudo',
      ),
      seedEmbedding: Float32List(1280),
      chips: Map<SteerChip, ChipState>.unmodifiable(chips),
      history: List<int>.unmodifiable(history),
      lastPickArtistKey: picks.isEmpty ? null : picks.last.artistKey,
    );
  }

  // ------------------------------------------------------------------
  // (5) NARRATE — apply swaps with validation.
  // ------------------------------------------------------------------

  _SwapApply _applySwaps({
    required List<CandidateMeta> ordered,
    required FinalPass fp,
    required List<_RankedCandidate> ranked,
  }) {
    final inOrdered = <int>{for (final m in ordered) m.trackId};
    final byId = <int, CandidateMeta>{
      for (final r in ranked) r.meta.trackId: r.meta,
    };
    final invalid = <Swap>[];
    final mutable = <CandidateMeta>[...ordered];
    for (final swap in fp.swaps) {
      if (swap.dropIndex < 0 || swap.dropIndex >= mutable.length) {
        invalid.add(swap);
        continue;
      }
      final insertMeta = byId[swap.insertTrackId];
      if (insertMeta == null) {
        // Not in top-40 — drop.
        invalid.add(swap);
        continue;
      }
      if (inOrdered.contains(swap.insertTrackId)) {
        // Already present — degenerate; drop.
        invalid.add(swap);
        continue;
      }
      final dropped = mutable[swap.dropIndex];
      inOrdered.remove(dropped.trackId);
      mutable[swap.dropIndex] = insertMeta;
      inOrdered.add(insertMeta.trackId);
    }
    return _SwapApply(ordered: mutable, invalid: invalid);
  }

  String _defaultBlurb(Intent intent) {
    final n = intent.narrative.trim();
    if (n.isEmpty) {
      return 'A flow-scored playlist tuned to your vibe.';
    }
    final tail = n.endsWith('.') || n.endsWith('!') || n.endsWith('?')
        ? n
        : '$n.';
    return tail.length > 240 ? tail.substring(0, 240) : tail;
  }
}

class _RankedCandidate {
  final CandidateMeta meta;
  final Float32List embedding;
  final double cosine;
  const _RankedCandidate(this.meta, this.embedding, this.cosine);
}

class _SwapApply {
  final List<CandidateMeta> ordered;
  final List<Swap> invalid;
  const _SwapApply({required this.ordered, required this.invalid});
}

class _IntentOutcome {
  final Intent intent;
  final bool usedFallback;
  const _IntentOutcome({required this.intent, required this.usedFallback});
}
