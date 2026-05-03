import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'chip_weights.dart';
import 'flow.dart';
import 'pick_result.dart';
import 'radio_session.dart';
import 'repo.dart';
import 'steer_chip.dart';

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
///   5. Return [PickResult] with new history + ticked chips
class RadioEngine {
  final FlowScorer flow;
  final ChipWeights weights;

  /// Below this many neighbours, `next` calls
  /// [PlaylistRepo.libraryWideFallback] (§10 risk 1).
  final int sparseFallbackThreshold;

  /// Distance kernel temperature — sim = exp(-l2 / τ).
  final double simTau;

  const RadioEngine({
    this.flow = const FlowScorer(),
    this.weights = const ChipWeights(),
    this.sparseFallbackThreshold = 50,
    this.simTau = 0.5,
  });

  /// Builds a session seeded from a single track. The seed
  /// embedding is fetched from the repo and L2-normalized.
  static Future<RadioSession> fromTrack({
    required int trackId,
    required String title,
    required PlaylistRepo repo,
  }) async {
    final raw = await repo.embeddingOf(trackId);
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

    // Fetch top-200 neighbours.
    final hits = await repo.knnByEmbedding(session.seedEmbedding, k: 200);

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
    if (heap.isEmpty) return null;
    final picked = heap.first;
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
}

class _Scored {
  final CandidateMeta meta;
  final double score;
  final double sim;
  final double chip;
  final double flowBonus;
  const _Scored(this.meta, this.score, this.sim, this.chip, this.flowBonus);
}
