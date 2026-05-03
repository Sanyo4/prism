import 'dart:math' as math;
import 'dart:typed_data';

// TODO(slice-6-integration): tighten to the playlist_engine barrel
// once Track A exports intent.dart / repo.dart's TrackRepo. Today the
// barrel surface ships the slice-5 names; deeper paths cover the rest.
import 'package:prism_playlist_engine/intent.dart' as engine_intent;
import 'package:prism_playlist_engine/playlist_engine.dart' as engine;
import 'package:prism_playlist_engine/prompts/mood_lookup.dart';

import 'cache_db.dart';
import 'playlist_repo_impl.dart';

/// `CacheDb`-backed implementation of [engine.TrackRepo] — slice 6's
/// extension of [PlaylistRepoImpl] that adds the SQL-filter candidate
/// pool and the keyword-driven mean-embedding helper.
///
/// Subclasses [PlaylistRepoImpl] so slice-5 surface (embeddingOf,
/// meanEmbeddingForAlbum/Artist, knnByEmbedding, metaOf, metaOfMany,
/// libraryWideFallback) is inherited verbatim. Slice-6 §6 owns the
/// dynamic SQL — `candidatePoolByIntent` rebuilds its WHERE clause
/// per [engine.RelaxationLevel] and ORDERs by the primary mood
/// column descending so the engine's centroid rank step sees the
/// highest-mood rows first regardless of any LIMIT truncation.
///
/// The class keeps its own [CacheDb] reference (alongside the one
/// stored privately by [PlaylistRepoImpl]) rather than reaching into
/// the parent's private field — keeps `PlaylistRepoImpl` (slice-5
/// owned) untouched and avoids a leaky `protected` getter.
class TrackRepoImpl extends PlaylistRepoImpl implements engine.TrackRepo {
  /// Local handle to the same [CacheDb] passed to the super-class.
  /// Held twice so this file doesn't need to widen
  /// [PlaylistRepoImpl]'s private surface.
  final CacheDb _db;

  // ignore: use_super_parameters
  TrackRepoImpl(CacheDb db, {math.Random? random})
      : _db = db,
        super(db, random: random);

  /// Slice plan §6 step 6 — dynamic SQL. The five `mood_*` predicates
  /// only fire when the corresponding `MoodTarget.min` is set; the
  /// `bpm_range` and `era` predicates only when the LLM didn't omit
  /// them. `loose` widens BPM ±10 and drops era; `veryLoose` keeps
  /// only the primary mood clause and doubles `LIMIT`. The relaxed
  /// intent is computed via [engine_intent.Intent.copyRelaxed], which
  /// already encodes those rules — we just rebuild the WHERE off the
  /// relaxed copy.
  @override
  Future<List<int>> candidatePoolByIntent(
    engine_intent.Intent intent, {
    int poolSize = 200,
    engine_intent.RelaxationLevel relax = engine_intent.RelaxationLevel.strict,
  }) async {
    final effective = intent.copyRelaxed(relax);
    final limit = relax == engine_intent.RelaxationLevel.veryLoose
        ? poolSize * 2
        : poolSize;

    final wheres = <String>["status = 'ready'"];
    final args = <Object?>[];

    final bpm = effective.bpmRange;
    if (bpm != null) {
      wheres.add('bpm IS NOT NULL AND bpm BETWEEN ? AND ?');
      args
        ..add(bpm.$1)
        ..add(bpm.$2);
    }

    final era = effective.era;
    if (era != null) {
      wheres.add('year IS NOT NULL AND year BETWEEN ? AND ?');
      args
        ..add(era.$1)
        ..add(era.$2);
    }

    // Mood predicates. Each MoodTarget contributes a `mood_<m> >= ?`
    // when min is set, plus a `mood_<m> <= ?` when max is set.
    String? primaryMoodCol;
    for (final mt in effective.moodTargets) {
      final col = _moodColumnFor(mt.mood);
      if (col == null) continue;
      primaryMoodCol ??= col;
      if (mt.min != null) {
        wheres.add('$col >= ?');
        args.add(mt.min);
      }
      if (mt.max != null) {
        wheres.add('$col <= ?');
        args.add(mt.max);
      }
    }
    primaryMoodCol ??= 'mood_relaxed';

    final sql = StringBuffer()
      ..writeln('SELECT id FROM tracks')
      ..writeln(' WHERE ${wheres.join(' AND ')}')
      ..writeln(' ORDER BY $primaryMoodCol DESC')
      ..writeln(' LIMIT ?');
    args.add(limit);

    final rows = await _db.writer.rawQuery(sql.toString(), args);
    return [for (final r in rows) r['id'] as int];
  }

  /// Snap each keyword via `MoodLookup.snap`, then take the top
  /// embeddings (by primary mood column DESC, `status='ready'`) for
  /// each mood and L2-normalize their mean. Empty input falls
  /// through to the global mean of the first ~100 ready embeddings.
  @override
  Future<Float32List> meanEmbeddingForKeywords(List<String> keywords) async {
    if (keywords.isEmpty) {
      return _globalFallbackMean();
    }
    // Map keywords → snapped 5-mood vocabulary; dedupe so two
    // synonyms ("rainy"+"chill") don't double the same kernel.
    final moods = <String>{};
    for (final k in keywords) {
      final snapped = MoodLookup.snap(k);
      moods.add(snapped);
    }
    final ids = <int>{};
    for (final mood in moods) {
      final col = _moodColumnFor(mood);
      if (col == null) continue;
      final rows = await _db.writer.rawQuery(
        "SELECT id FROM tracks WHERE status = 'ready' "
        'ORDER BY $col DESC LIMIT 20',
      );
      for (final r in rows) {
        ids.add(r['id'] as int);
      }
    }
    if (ids.isEmpty) {
      return _globalFallbackMean();
    }
    final mean = await _meanOfIds(ids.toList(growable: false));
    if (mean == null) {
      return _globalFallbackMean();
    }
    return mean;
  }

  /// Global fallback for `meanEmbeddingForKeywords` — random sample
  /// of `status='ready'` rows (via the inherited `libraryWideFallback`)
  /// L2-normalized. Returns a zero vector when the library is empty,
  /// which the engine tolerates (cosine ranks degenerate to ties; SQL
  /// row order then dominates).
  Future<Float32List> _globalFallbackMean() async {
    final ids = await libraryWideFallback(limit: 100);
    if (ids.isEmpty) return Float32List(1280);
    final mean = await _meanOfIds(ids);
    return mean ?? Float32List(1280);
  }

  /// L2-normalized mean of the embedding rows for [trackIds]. Mirrors
  /// the parent's private helper — kept verbatim here so this file
  /// doesn't require widening [PlaylistRepoImpl]'s surface. Decodes
  /// 1280-dim float32-LE blobs; rows whose blob shape is wrong are
  /// silently skipped (they'd surface as `ArgumentError` on a direct
  /// `embeddingOf` call but are benign for a mean over a candidate
  /// set).
  Future<Float32List?> _meanOfIds(List<int> trackIds) async {
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
      if (raw.length != 1280 * 4) continue;
      final view = ByteData.sublistView(raw);
      for (var i = 0; i < 1280; i++) {
        acc[i] += view.getFloat32(i * 4, Endian.little);
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

  /// Maps a 5-mood key to the corresponding `mood_*` column. Returns
  /// null for inputs the lookup table doesn't recognise (the snap
  /// step keeps that from happening in practice; defensive only).
  static String? _moodColumnFor(String mood) {
    switch (mood) {
      case 'happy':
        return 'mood_happy';
      case 'sad':
        return 'mood_sad';
      case 'aggressive':
        return 'mood_aggressive';
      case 'relaxed':
        return 'mood_relaxed';
      case 'party':
        return 'mood_party';
      default:
        return null;
    }
  }
}
