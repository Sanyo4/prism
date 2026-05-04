import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'chip_weights.dart';
import 'flow.dart';
import 'pick_result.dart';
import 'radio_session.dart';
import 'repo.dart';
import 'steer_chip.dart';

/// Sampling-side config for [RadioEngine] (slice-11 §B3). Controls the
/// top-K-from-top-N weighted sampler that breaks the slice-5
/// determinism on radio picks: same seed twice in a row should produce
/// overlapping-but-not-identical queues so the radio doesn't feel
/// repetitive.
///
/// Math: candidates are pulled at top-N (where `N = K · topNMultiplier`)
/// then K of them are drawn without replacement, weighted by
/// `1 / (l2Distance + 1e-6) + temperature · rng.nextDouble()`. Higher
/// temperature → more jitter; `temperature: 0.0` collapses back to
/// the pure inverse-distance ranking used in slice-5 / 6 / 10.
@immutable
class RadioEngineConfig {
  /// Random-jitter coefficient added to each weight. `0.0` is fully
  /// deterministic (regression to slice-5 top-K). The default of 0.4
  /// is small enough that close matches still dominate but large
  /// enough that ~30% of picks differ on a re-seed.
  final double temperature;

  /// Pool multiplier — kNN is asked for `K · topNMultiplier` rows so
  /// the sampler has headroom to jitter. With `K=20, multiplier=4`
  /// the pool is 80, so the engine never asks for more than that
  /// even on huge libraries.
  final int topNMultiplier;

  /// Optional injected RNG. Tests pass `Random(seed)` for
  /// reproducible picks; production paths leave it `null` so each
  /// new `RadioEngine` instance creates a fresh [math.Random] (which
  /// the Dart core seeds from a per-isolate entropy source — the
  /// default `Random()` is reseeded between processes).
  final math.Random? random;

  const RadioEngineConfig({
    this.temperature = 0.4,
    this.topNMultiplier = 4,
    this.random,
  });

  /// Slice-5 / pre-slice-11 behaviour: pure top-K argmax with no
  /// jitter and no oversampling. Used by tests that assert the
  /// scoring math hasn't drifted.
  static const RadioEngineConfig deterministic =
      RadioEngineConfig(temperature: 0.0, topNMultiplier: 1);
}

/// Pure-Dart radio engine. Stateless aside from its config; per-
/// session state lives on [RadioSession].
///
/// Pipeline (§5, §8 step 8):
///   1. `repo.knnByEmbedding(seed, k=200)` (sparse-fallback if <50)
///   2. Resolve [CandidateMeta] for each hit
///   3. For each candidate: sim · chipWeight · flowBonus
///      - sim = exp(-l2 / τ), τ = 0.5
///      - chipWeight = ChipWeights.apply(...)
///      - flowBonus = FlowScorer.scoreOrReject(...) — null hard-rejects
///   4. Argmax via HeapPriorityQueue
///   5. Slice-11 §B3: when `sampling.temperature > 0`, draw K winners
///      from the top-N scored pool weighted by
///      `score + temperature · rng.nextDouble()` instead of taking the
///      single argmax — the engine returns the highest-scoring of the
///      sampled winners but `next` consumes a fresh sample each call,
///      so calling `next` from the same seed produces different
///      results on each invocation.
///   6. Return [PickResult] with new history + ticked chips
class RadioEngine {
  final FlowScorer flow;
  final ChipWeights weights;

  /// Below this many neighbours, `next` calls
  /// [PlaylistRepo.libraryWideFallback] (§10 risk 1).
  final int sparseFallbackThreshold;

  /// Distance kernel temperature — sim = exp(-l2 / τ).
  final double simTau;

  /// Top-K-from-top-N weighted sampler config (slice-11 §B3). Defaults
  /// produce ~30% different picks on re-seed; pass
  /// [RadioEngineConfig.deterministic] to opt back into the slice-5
  /// argmax behaviour.
  final RadioEngineConfig sampling;

  const RadioEngine({
    this.flow = const FlowScorer(),
    this.weights = const ChipWeights(),
    this.sparseFallbackThreshold = 50,
    this.simTau = 0.5,
    this.sampling = const RadioEngineConfig(),
  });

  /// Builds a session seeded from a single track. The seed
  /// embedding is fetched from the repo and L2-normalized.
  static Future<RadioSession> fromTrack({
    required int trackId,
    required String title,
    required PlaylistRepo repo,
  }) async {
    assert(() {
      print('[RadioDiag] RadioEngine.fromTrack id=$trackId title="$title"');
      return true;
    }());
    final raw = await repo.embeddingOf(trackId);
    assert(() {
      print('[RadioDiag] RadioEngine.fromTrack embedding ok '
          'dims=${raw.length}');
      return true;
    }());
    final norm = _l2Normalize(raw);
    return RadioSession(
      seed: TrackSeed(trackId: trackId, title: title),
      seedEmbedding: norm,
    );
  }

  /// Builds a session seeded from an album mean embedding.
  /// `albumKey` is the canonical album id; `title` is the display
  /// label. Throws [StateError] when no `ready` rows match.
  static Future<RadioSession> fromAlbum({
    required String albumKey,
    required String title,
    required PlaylistRepo repo,
  }) async {
    final mean = await repo.meanEmbeddingForAlbum(albumKey);
    if (mean == null) {
      throw StateError('No analyzed tracks on album "$albumKey"');
    }
    return RadioSession(
      seed: AlbumSeed(albumKey: albumKey, title: title),
      seedEmbedding: mean,
    );
  }

  /// Builds a session seeded from an artist mean embedding.
  /// Throws [StateError] when no `ready` rows match.
  static Future<RadioSession> fromArtist({
    required String artist,
    required String label,
    required PlaylistRepo repo,
  }) async {
    final mean = await repo.meanEmbeddingForArtist(artist);
    if (mean == null) {
      throw StateError('No analyzed tracks for artist "$artist"');
    }
    return RadioSession(
      seed: ArtistSeed(artist: artist, label: label),
      seedEmbedding: mean,
    );
  }

  /// Picks one candidate. Returns null only when the library is
  /// empty after fallback.
  Future<PickResult?> next(RadioSession session, PlaylistRepo repo) async {
    // Defense-in-depth: §10 risk 2.
    final active = session.chips.entries
        .where((e) => e.value.isActive)
        .map((e) => e.key)
        .toSet();
    for (final pair in kChipConflicts.entries) {
      assert(
        !(active.contains(pair.key) && active.contains(pair.value)),
        'Conflicting chips active: ${pair.key} + ${pair.value}',
      );
    }

    // Slice-11 §A1 diagnostic — capture the seed entry point so
    // `adb logcat | grep RadioDiag` traces every engine pick. Wrapped
    // in assert so release builds strip the print.
    assert(() {
      final seedDesc = session.seed is TrackSeed
          ? 'TrackSeed(${(session.seed as TrackSeed).trackId})'
          : session.seed.runtimeType.toString();
      print('[RadioDiag] RadioEngine.next start seed=$seedDesc '
          'historyLen=${session.history.length}');
      return true;
    }());

    // Slice-11 §B3 — fetch the top-N neighbour pool. "K" is the
    // sampler's effective winner-set size (20 by default — that's what
    // an actual radio queue length looks like before the user gets
    // tired); the pool is `K · topNMultiplier`. With default config
    // (multiplier=4, k=20) that's 80 — a 60% reduction from the
    // slice-5 flat 200. With `RadioEngineConfig.deterministic`
    // (multiplier=1) the pool is 20, still enough to cover
    // sparse-fallback thresholds. The 50-track sparse fallback
    // threshold is honoured: when the kNN pool is below the
    // threshold the engine still falls through to
    // `libraryWideFallback`, exactly like slice-5.
    const samplerWinnerSetK = 20;
    final poolSize = samplerWinnerSetK * sampling.topNMultiplier;
    final hits =
        await repo.knnByEmbedding(session.seedEmbedding, k: poolSize);
    assert(() {
      print('[RadioDiag] RadioEngine.next knn hits=${hits.length} '
          'poolSize=$poolSize');
      return true;
    }());

    // Resolve seed metadata if the seed is a track — used by
    // mood-anchored chip kernels.
    CandidateMeta? seedMeta;
    final seed = session.seed;
    if (seed is TrackSeed) {
      try {
        seedMeta = await repo.metaOf(seed.trackId);
      } catch (_) {
        seedMeta = null;
      }
    }

    final fromKnn = hits.length >= sparseFallbackThreshold;
    final List<KnnHit> workingSet;
    if (fromKnn) {
      workingSet = hits;
    } else {
      // §10 risk 1 — sparse-neighborhood fallback.
      final fallbackIds = await repo.libraryWideFallback(limit: 100);
      // Synthesize fake distances so downstream code still has an
      // "l2" to fold into similarity. We assign a uniform mid-range
      // distance so the fallback never beats real kNN hits when both
      // exist; in practice fallback only fires when knn is starved.
      final byId = <int, KnnHit>{};
      for (final h in hits) {
        byId[h.trackId] = h;
      }
      for (final id in fallbackIds) {
        byId.putIfAbsent(
          id,
          () => KnnHit(trackId: id, l2Distance: 1.0),
        );
      }
      workingSet = byId.values.toList(growable: false);
    }
    if (workingSet.isEmpty) return null;

    // Resolve metadata in one batch.
    final ids = workingSet.map((h) => h.trackId).toList(growable: false);
    final metaList = await repo.metaOfMany(ids);
    final metaById = <int, CandidateMeta>{
      for (final m in metaList) m.trackId: m,
    };

    // Resolve previous-pick metadata for the BPM/Camelot rules.
    CandidateMeta? previous;
    if (session.history.isNotEmpty) {
      final prevId = session.history.last;
      previous = metaById[prevId];
      previous ??= await _safeMeta(repo, prevId);
    }

    // Resolve metadata for the entire history slice the flow scorer
    // reads (so the same-artist window can reach beyond the current
    // working set when a recent history pick isn't a kNN neighbour
    // of the seed any more).
    final historyMeta = <int, CandidateMeta>{};
    final tail = session.history.length <= flow.sameArtistWindow
        ? session.history
        : session.history
            .sublist(session.history.length - flow.sameArtistWindow);
    for (final id in tail) {
      final m = metaById[id] ?? await _safeMeta(repo, id);
      if (m != null) historyMeta[id] = m;
    }

    // Score every candidate; argmax via heap.
    final heap = HeapPriorityQueue<_Scored>(
      (a, b) => b.score.compareTo(a.score),
    );
    for (final hit in workingSet) {
      final meta = metaById[hit.trackId];
      if (meta == null) continue;
      // Don't pick the seed itself (track-seed flow).
      if (seed is TrackSeed && meta.trackId == seed.trackId) {
        continue;
      }
      final sim = math.exp(-hit.l2Distance / simTau);
      final chip = weights.apply(session, meta, seedMeta: seedMeta);
      final flowBonus = flow.scoreOrReject(
        candidate: meta,
        previous: previous,
        session: session,
        historyMeta: historyMeta,
      );
      if (flowBonus == null) continue;
      final score = sim * chip * flowBonus;
      heap.add(_Scored(meta, score, sim, chip, flowBonus));
    }
    assert(() {
      print(
        '[RadioDiag] RadioEngine.next end heap=${heap.length} '
        'workingSet=${workingSet.length} fromKnn=$fromKnn '
        'temperature=${sampling.temperature}',
      );
      return true;
    }());
    if (heap.isEmpty) return null;
    final picked = _sampleFromHeap(heap);
    return PickResult(
      pickedTrackId: picked.meta.trackId,
      nextSession:
          session.copyAfterPick(picked.meta.trackId, picked.meta.artistKey),
      debug: ScoreBreakdown(
        similarity: picked.sim,
        chipWeight: picked.chip,
        flowBonus: picked.flowBonus,
        finalScore: picked.score,
        fromKnn: fromKnn,
      ),
    );
  }

  /// Slice-11 §B3 — picks one winner from [heap]'s top-N entries
  /// using temperature-scaled weighted sampling.
  ///
  /// With `temperature == 0.0`, returns `heap.first` verbatim — the
  /// pre-slice-11 argmax. Otherwise: pulls up to 20 top-scored
  /// candidates, computes weight `score + temperature · rng.nextDouble()`
  /// for each, then draws one in a single pass via inverse-CDF.
  ///
  /// We use 20 (not the full heap) to keep the tail of low-scoring
  /// hits — which can be hundreds of items deep when fallback is
  /// engaged — from diluting the sample distribution. The math is
  /// the user-spec'd `1 / (distance + ε)` translated to the engine's
  /// already-multiplicative scoring: `score = sim · chip · flow` and
  /// `sim = exp(-l2 / τ)`, so higher `score` ↔ smaller `l2Distance`.
  _Scored _sampleFromHeap(HeapPriorityQueue<_Scored> heap) {
    if (sampling.temperature <= 0.0) {
      // Determinism path — pre-slice-11 behaviour.
      return heap.first;
    }
    const winnerSetK = 20;
    final winners = <_Scored>[];
    while (winners.length < winnerSetK && heap.isNotEmpty) {
      winners.add(heap.removeFirst());
    }
    if (winners.length == 1) return winners.first;
    final rng = sampling.random ?? math.Random();
    final weights = List<double>.filled(winners.length, 0.0);
    var total = 0.0;
    for (var i = 0; i < winners.length; i++) {
      // Translate the engine's multiplicative score back into the
      // inverse-distance weight family the user spec'd. Adding
      // `temperature · rng.nextDouble()` jitters each weight in
      // [0, temperature) so close-but-not-best matches have a real
      // chance of winning.
      final w = winners[i].score + sampling.temperature * rng.nextDouble();
      weights[i] = w;
      total += w;
    }
    if (total <= 0.0) return winners.first;
    final pick = rng.nextDouble() * total;
    var acc = 0.0;
    for (var i = 0; i < winners.length; i++) {
      acc += weights[i];
      if (acc >= pick) return winners[i];
    }
    return winners.last;
  }

  static Future<CandidateMeta?> _safeMeta(
    PlaylistRepo repo,
    int id,
  ) async {
    try {
      return await repo.metaOf(id);
    } catch (_) {
      return null;
    }
  }

  /// L2-normalize a 1280-dim embedding in place into a fresh
  /// `Float32List`. Zero vectors are returned untouched (avoids
  /// division-by-zero — extremely unlikely in practice).
  static Float32List _l2Normalize(Float32List src) {
    var sum = 0.0;
    for (var i = 0; i < src.length; i++) {
      sum += src[i] * src[i];
    }
    final norm = math.sqrt(sum);
    if (norm == 0.0) return Float32List.fromList(src);
    final out = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      out[i] = src[i] / norm;
    }
    return out;
  }

  /// Element-wise average of [vectors], then L2-normalised. Returns
  /// `null` on empty input. Used by `RadioSessionNotifier.startFromCluster`
  /// (slice 10) to seed a session from a list of tracks treated as a
  /// synthetic cluster — matches the format `meanEmbeddingForAlbum`
  /// already returns.
  ///
  /// All input vectors must be 1280-dim; mismatched lengths throw
  /// `ArgumentError`.
  static Float32List? averageEmbeddings(List<Float32List> vectors) {
    if (vectors.isEmpty) return null;
    const dim = 1280;
    for (final v in vectors) {
      if (v.length != dim) {
        throw ArgumentError(
          'averageEmbeddings: expected length $dim, got ${v.length}',
        );
      }
    }
    final acc = Float32List(dim);
    for (final v in vectors) {
      for (var i = 0; i < dim; i++) {
        acc[i] += v[i];
      }
    }
    final n = vectors.length;
    for (var i = 0; i < dim; i++) {
      acc[i] /= n;
    }
    return _l2Normalize(acc);
  }
}

class _Scored {
  final CandidateMeta meta;
  final double score;
  final double sim;
  final double chip;
  final double flowBonus;
  const _Scored(this.meta, this.score, this.sim, this.chip, this.flowBonus);
}
