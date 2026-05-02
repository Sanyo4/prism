import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One vec0 hit — `trackId` plus its L2 distance from the seed
/// embedding. Implementations must filter to `status='ready'` rows.
@immutable
class KnnHit {
  final int trackId;
  final double l2Distance;
  const KnnHit({required this.trackId, required this.l2Distance});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnnHit &&
          other.trackId == trackId &&
          other.l2Distance == l2Distance);

  @override
  int get hashCode => Object.hash(trackId, l2Distance);
}

/// Per-track metadata the engine needs to score a candidate. Numeric
/// fields default to zero when the underlying column is null — the
/// engine never branches on null mood values; missing data simply
/// counts as neutral.
@immutable
class CandidateMeta {
  final int trackId;

  /// Stable artist identity. Slice 5 lowercases artist strings into
  /// this key inside the repo adapter (`artist?.toLowerCase().trim()`)
  /// so "The Cure" and "the cure" share an artist window.
  final String artistKey;

  /// Display title — used by the seed-label rendering only.
  final String title;

  /// Camelot-parseable key string from the sidecar (`'Fm'`, `'C#'`,
  /// `'D minor'`, ...). Empty string when missing; `Camelot.parse`
  /// returns null on empty / unparseable.
  final String key;

  /// Year tag (release year), null when absent. Drives
  /// `newer`/`older` chip kernels.
  final int? year;

  final double bpm;
  final double moodHappy;
  final double moodSad;
  final double moodRelaxed;
  final double moodAggressive;
  final double moodParty;
  final double danceability;
  final double voiceInstrumental;

  const CandidateMeta({
    required this.trackId,
    required this.artistKey,
    required this.title,
    required this.key,
    required this.year,
    required this.bpm,
    required this.moodHappy,
    required this.moodSad,
    required this.moodRelaxed,
    required this.moodAggressive,
    required this.moodParty,
    required this.danceability,
    required this.voiceInstrumental,
  });
}

/// Port between the pure-Dart engine and the storage layer.
/// `packages/core` ships [PlaylistRepoImpl] over `CacheDb`. Tests use
/// an in-memory [FakeRepo] under `test/fakes/` — both compile without
/// SQLite.
abstract class PlaylistRepo {
  /// Returns the 1280-dim embedding for [trackId] as a freshly-allocated
  /// `Float32List`. Throws [ArgumentError] when the stored blob is the
  /// wrong length (slice 5 §10 risk 8 — defends against analyzer drift
  /// to 768 dims). Throws [StateError] when the row is missing.
  Future<Float32List> embeddingOf(int trackId);

  /// L2-normalized mean of all `status='ready'` embeddings whose
  /// album equals [albumKey]. Returns null when no rows match
  /// (slice 5 §10 risk 6).
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey);

  /// L2-normalized mean of all `status='ready'` embeddings whose
  /// artist equals [artist]. Returns null when no rows match.
  Future<Float32List?> meanEmbeddingForArtist(String artist);

  /// Top-[k] neighbours of [seed] under L2 distance, restricted to
  /// `status='ready'` rows. Hits are returned in ascending distance
  /// order with the seed itself excluded (callers that pass a seed
  /// matching an embedding row should filter by id post-hoc).
  Future<List<KnnHit>> knnByEmbedding(Float32List seed, {int k = 200});

  /// Per-track metadata for engine scoring. Implementations should
  /// batch internally when called repeatedly inside one `next` pass.
  Future<CandidateMeta> metaOf(int trackId);

  /// Best-effort batch resolve. Default implementation defers to
  /// [metaOf]; the SQLite adapter overrides with a single
  /// `IN (...)` query.
  Future<List<CandidateMeta>> metaOfMany(Iterable<int> ids) async {
    final out = <CandidateMeta>[];
    for (final id in ids) {
      out.add(await metaOf(id));
    }
    return out;
  }

  /// Random sample of `status='ready'` track ids. Used by
  /// `RadioEngine.next` when the seed's neighbourhood is sparse
  /// (§10 risk 1).
  Future<List<int>> libraryWideFallback({int limit = 100});
}
