import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart' as engine;

import 'cache_db.dart';
import 'vec_loader.dart';

/// `CacheDb`-backed implementation of [engine.PlaylistRepo]. The
/// only file in `packages/core` that bridges the pure-Dart engine
/// to SQLite — keeping it isolated lets the engine's tests run
/// without an FFI handle, and lets the slice-6 LLM playlist engine
/// reuse the same port (slice 5 plan §6 / §7).
///
/// Wraps an existing [CacheDb]; does **not** open or close it. The
/// owning provider keeps the DB handle alive for the lifetime of
/// the radio session.
class PlaylistRepoImpl implements engine.PlaylistRepo {
  final CacheDb _db;

  /// Random source used by [libraryWideFallback]. Deterministic by
  /// default for tests; production callers can pass `math.Random()`.
  final math.Random _rng;

  PlaylistRepoImpl(this._db, {math.Random? random})
      : _rng = random ?? math.Random(0);

  /// Decodes the 1280-dim float32-LE blob stored in
  /// `track_embeddings.embedding` for [trackId]. Throws
  /// [ArgumentError] when the blob is not exactly 5120 bytes
  /// (slice 5 §10 risk 8 — guards against future analyzer drift to
  /// 768 dims). Throws [StateError] when no row exists or when
  /// [Vec0Loader.loadFailed] is true (degraded mode).
  @override
  Future<Float32List> embeddingOf(int trackId) async {
    if (Vec0Loader.loadFailed) {
      throw StateError(
        'Embeddings unavailable — vec0 load failed: '
        '${Vec0Loader.loadFailureMessage}',
      );
    }
    final rows = _db.reader.select(
      'SELECT embedding FROM track_embeddings WHERE track_id = ?',
      [trackId],
    );
    if (rows.isEmpty) {
      throw StateError('no embedding for track_id $trackId');
    }
    final raw = rows.first['embedding'];
    if (raw is! Uint8List) {
      throw StateError(
        'embedding column for $trackId returned ${raw.runtimeType}',
      );
    }
    return _decodeEmbedding(raw);
  }

  /// L2-normalized mean of every `status='ready'` embedding whose
  /// row's `album` column equals [albumKey]. `null` when no such
  /// rows exist (album with no analysed tracks — §10 risk 6), or
  /// when [Vec0Loader.loadFailed] is true (degraded mode).
  @override
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey) async {
    if (Vec0Loader.loadFailed) return null;
    final ids = await _db.writer.rawQuery(
      'SELECT id FROM tracks '
      "WHERE status = 'ready' AND album = ?",
      [albumKey],
    );
    return _meanOfTrackIds(
      ids.map((r) => r['id'] as int).toList(growable: false),
    );
  }

  /// L2-normalized mean of every `status='ready'` embedding whose
  /// row's `artist` column equals [artist]. `null` when no rows
  /// match, or when [Vec0Loader.loadFailed] is true (degraded mode).
  @override
  Future<Float32List?> meanEmbeddingForArtist(String artist) async {
    if (Vec0Loader.loadFailed) return null;
    final ids = await _db.writer.rawQuery(
      'SELECT id FROM tracks '
      "WHERE status = 'ready' AND artist = ?",
      [artist],
    );
    return _meanOfTrackIds(
      ids.map((r) => r['id'] as int).toList(growable: false),
    );
  }

  /// vec0 kNN against [seed], joined to `tracks` for the
  /// `status='ready'` filter. Returns up to [k] hits ascending by
  /// L2 distance, or an empty list when [Vec0Loader.loadFailed] is
  /// true (degraded mode — radio unavailable).
  @override
  Future<List<engine.KnnHit>> knnByEmbedding(
    Float32List seed, {
    int k = 200,
  }) async {
    if (Vec0Loader.loadFailed) return <engine.KnnHit>[];
    final blob = _encodeEmbedding(seed);
    final hits = _db.reader.select(
      '''
      SELECT track_id, distance
        FROM track_embeddings
       WHERE embedding MATCH ? AND k = ?
       ORDER BY distance
      ''',
      [blob, k],
    );
    if (hits.isEmpty) return const [];

    final candidateIds = <int>[
      for (final r in hits) r['track_id'] as int,
    ];
    final placeholders = List.filled(candidateIds.length, '?').join(',');
    final readyRows = await _db.writer.rawQuery(
      'SELECT id FROM tracks '
      "WHERE status = 'ready' AND id IN ($placeholders)",
      candidateIds,
    );
    final readyIds = <int>{for (final r in readyRows) r['id'] as int};

    final out = <engine.KnnHit>[];
    for (final r in hits) {
      final id = r['track_id'] as int;
      if (!readyIds.contains(id)) continue;
      out.add(engine.KnnHit(
        trackId: id,
        l2Distance: (r['distance'] as num).toDouble(),
      ));
      if (out.length >= k) break;
    }
    return out;
  }

  /// One-shot per-id meta lookup — drives the `previous` and
  /// `historyMeta` reads inside [engine.RadioEngine.next]. Heavy paths
  /// should batch via [metaOfMany].
  @override
  Future<engine.CandidateMeta> metaOf(int trackId) async {
    final rows = await _db.writer.rawQuery(
      _candidateMetaSql('id = ?'),
      [trackId],
    );
    if (rows.isEmpty) {
      throw StateError('no track row for id $trackId');
    }
    return _rowToMeta(rows.first);
  }

  /// Batched lookup; one `IN (...)` round-trip for the kNN candidate
  /// set. Skips ids missing from the result silently.
  @override
  Future<List<engine.CandidateMeta>> metaOfMany(Iterable<int> ids) async {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return const [];
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await _db.writer.rawQuery(
      _candidateMetaSql('id IN ($placeholders)'),
      list,
    );
    return [for (final r in rows) _rowToMeta(r)];
  }

  /// Random sample of `status='ready'` track ids. Used by the
  /// engine when a seed has < 50 kNN neighbours (§10 risk 1).
  @override
  Future<List<int>> libraryWideFallback({int limit = 100}) async {
    final rows = await _db.writer.rawQuery(
      "SELECT id FROM tracks WHERE status = 'ready'",
    );
    final ids = [for (final r in rows) r['id'] as int]..shuffle(_rng);
    if (ids.length <= limit) return ids;
    return ids.sublist(0, limit);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<Float32List?> _meanOfTrackIds(List<int> trackIds) async {
    if (trackIds.isEmpty) return null;
    final placeholders = List.filled(trackIds.length, '?').join(',');
    final rows = _db.reader.select(
      'SELECT embedding FROM track_embeddings '
      'WHERE track_id IN ($placeholders)',
      trackIds,
    );
    if (rows.isEmpty) return null;
    final acc = Float32List(1280);
    var n = 0;
    for (final r in rows) {
      final raw = r['embedding'];
      if (raw is! Uint8List) continue;
      final v = _decodeEmbedding(raw);
      for (var i = 0; i < 1280; i++) {
        acc[i] += v[i];
      }
      n++;
    }
    if (n == 0) return null;
    var sumSq = 0.0;
    for (var i = 0; i < 1280; i++) {
      acc[i] /= n;
      sumSq += acc[i] * acc[i];
    }
    final norm = math.sqrt(sumSq);
    if (norm == 0.0) return acc;
    final out = Float32List(1280);
    for (var i = 0; i < 1280; i++) {
      out[i] = acc[i] / norm;
    }
    return out;
  }

  static const int _expectedDims = 1280;
  static const int _expectedBytes = _expectedDims * 4;

  static Float32List _decodeEmbedding(Uint8List raw) {
    if (raw.length != _expectedBytes) {
      throw ArgumentError(
        'expected $_expectedDims, got ${raw.length ~/ 4}',
      );
    }
    final out = Float32List(_expectedDims);
    final view = ByteData.sublistView(raw);
    for (var i = 0; i < _expectedDims; i++) {
      out[i] = view.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  static Uint8List _encodeEmbedding(Float32List src) {
    if (src.length != _expectedDims) {
      throw ArgumentError(
        'expected $_expectedDims, got ${src.length}',
      );
    }
    final out = ByteData(_expectedBytes);
    for (var i = 0; i < _expectedDims; i++) {
      out.setFloat32(i * 4, src[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  static String _candidateMetaSql(String whereClause) {
    return '''
      SELECT id, artist, title, key, year, bpm,
             mood_happy, mood_sad, mood_relaxed, mood_aggressive, mood_party,
             danceability, voice_instrumental
        FROM tracks
       WHERE $whereClause
    ''';
  }

  static engine.CandidateMeta _rowToMeta(Map<String, Object?> row) {
    final artist = (row['artist'] as String?) ?? '';
    return engine.CandidateMeta(
      trackId: row['id'] as int,
      artistKey: artist.toLowerCase().trim(),
      title: (row['title'] as String?) ?? '',
      key: (row['key'] as String?) ?? '',
      year: row['year'] as int?,
      bpm: (row['bpm'] as num?)?.toDouble() ?? 0.0,
      moodHappy: (row['mood_happy'] as num?)?.toDouble() ?? 0.0,
      moodSad: (row['mood_sad'] as num?)?.toDouble() ?? 0.0,
      moodRelaxed: (row['mood_relaxed'] as num?)?.toDouble() ?? 0.0,
      moodAggressive: (row['mood_aggressive'] as num?)?.toDouble() ?? 0.0,
      moodParty: (row['mood_party'] as num?)?.toDouble() ?? 0.0,
      danceability: (row['danceability'] as num?)?.toDouble() ?? 0.0,
      voiceInstrumental:
          (row['voice_instrumental'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
