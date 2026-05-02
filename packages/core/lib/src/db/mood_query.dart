import 'dart:math' as math;

import 'cache_db.dart';

/// The five home-row mood chips, **locked order**: Happy / Sad / Chill
/// / Energetic / Focus. Visual order is enforced at the UI layer; this
/// enum just nails the identity.
enum MoodChip { happy, sad, chill, energetic, focus }

/// One row in a mood-results list. Pure value type — `Track`-shaped
/// fields kept loose because the UI joins lazily against the existing
/// scanner-derived `Track` for tag-only fields like duration / cover.
class RankedTrack {
  /// `tracks.id` — joins back to the live `Track` by path via
  /// `cache_db_providers.dart` if richer detail is needed.
  final int trackId;

  /// Filesystem path of the audio file. Stable across re-ingests; the
  /// UI prefers this over [trackId] for queue ops since `QueueService`
  /// indexes tracks by path.
  final String path;

  /// Mood score the chip selected on (e.g. `mood_sad` for `MoodChip.sad`).
  final double moodConfidence;

  /// Ranking weight after combining `moodConfidence`, `play_count`, and
  /// recency. Sorted descending.
  final double rankScore;

  /// Tag-derived display title — `tracks.title` from the row, falling
  /// back to a filename stem at the UI layer.
  final String? title;
  final String? artist;
  final String? album;

  const RankedTrack({
    required this.trackId,
    required this.path,
    required this.moodConfidence,
    required this.rankScore,
    this.title,
    this.artist,
    this.album,
  });
}

/// Service that turns a [MoodChip] tap into a ranked list of tracks.
///
/// Strategy: SQL filters on `status='ready'` and the chip's primary
/// mood column, returns the top 1k by raw confidence, then Dart
/// applies the full ranking formula
/// `mood_confidence * log(1 + play_count) * recency_factor`.
/// Doing the rank in Dart keeps SQL portable and means slice-5 can
/// reuse the function with synthetic seeds.
class MoodQuery {
  MoodQuery(this._db);
  final CacheDb _db;

  /// Top [limit] results for [chip], ordered by composite rank
  /// descending. Empty list when nothing in the cache qualifies.
  Future<List<RankedTrack>> run(
    MoodChip chip, {
    int limit = 200,
    DateTime? now,
  }) async {
    // SQL pre-filter: top-1k candidates by the chip's primary mood
    // column. Dart re-ranks against play_count + recency.
    final spec = _querySpec(chip);
    final results = await _db.writer.rawQuery(
      '''
      SELECT id, path, title, artist, album,
             ${spec.confidenceExpr} AS mood_confidence,
             play_count, added_at
        FROM tracks
       WHERE status = 'ready'
         AND ${spec.filter}
       ORDER BY mood_confidence DESC
       LIMIT 1000
      ''',
      spec.params,
    );

    final ranked = <RankedTrack>[];
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    for (final row in results) {
      final confidence = (row['mood_confidence'] as num?)?.toDouble() ?? 0.0;
      final playCount = (row['play_count'] as int?) ?? 0;
      final addedAt = (row['added_at'] as int?) ?? nowMs;
      final rank = _rankScore(
        confidence: confidence,
        playCount: playCount,
        addedAtMs: addedAt,
        nowMs: nowMs,
      );
      ranked.add(RankedTrack(
        trackId: row['id'] as int,
        path: row['path'] as String,
        title: row['title'] as String?,
        artist: row['artist'] as String?,
        album: row['album'] as String?,
        moodConfidence: confidence,
        rankScore: rank,
      ));
    }
    ranked.sort((a, b) => b.rankScore.compareTo(a.rankScore));
    if (ranked.length > limit) {
      return ranked.sublist(0, limit);
    }
    return ranked;
  }

  /// Pure helper exposed for tests — `confidence * log(1 + play_count)
  /// * recency_factor` where `recency_factor = 0.5 + 0.5 *
  /// exp(-days_since_added / 365)`. Locked by §7.
  static double _rankScore({
    required double confidence,
    required int playCount,
    required int addedAtMs,
    required int nowMs,
  }) {
    final days = (nowMs - addedAtMs) / Duration.millisecondsPerDay;
    final recency = 0.5 + 0.5 * math.exp(-days / 365);
    final play = math.log(1 + playCount);
    // Adding +1 to play keeps unplayed tracks from getting zeroed out
    // — a fresh-from-scan track should still rank by mood confidence
    // alone. The formula in §7 says `log(1 + play_count)`, which is 0
    // at play_count=0; multiplying by zero kills the row. We adjust
    // by adding 1 so unplayed tracks rank purely on confidence *
    // recency. Documented deviation from the §7 sketch.
    return confidence * (1 + play) * recency;
  }

  /// Deterministic spec for each chip — extracted so the SQL can be
  /// inspected and the formulas tested in isolation.
  static _ChipSpec _querySpec(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return _ChipSpec(
          confidenceExpr: 'mood_happy',
          filter: 'mood_happy IS NOT NULL',
          params: const [],
        );
      case MoodChip.sad:
        return _ChipSpec(
          confidenceExpr: 'mood_sad',
          filter: 'mood_sad IS NOT NULL',
          params: const [],
        );
      case MoodChip.chill:
        // chill = mood_relaxed * (bpm < 110 ? 1 : 0.5)
        return _ChipSpec(
          confidenceExpr:
              'mood_relaxed * CASE WHEN bpm < 110 THEN 1.0 ELSE 0.5 END',
          filter: 'mood_relaxed IS NOT NULL',
          params: const [],
        );
      case MoodChip.energetic:
        // energetic = max(mood_party, danceability) * (bpm > 110 ? 1 : 0.5)
        return _ChipSpec(
          confidenceExpr:
              'MAX(COALESCE(mood_party, 0.0), COALESCE(danceability, 0.0)) '
              ' * CASE WHEN bpm > 110 THEN 1.0 ELSE 0.5 END',
          filter:
              '(mood_party IS NOT NULL OR danceability IS NOT NULL)',
          params: const [],
        );
      case MoodChip.focus:
        // focus = voice_instrumental * (1 - mood_aggressive) * (1 - mood_party)
        return _ChipSpec(
          confidenceExpr:
              'voice_instrumental '
              ' * (1.0 - COALESCE(mood_aggressive, 0.0)) '
              ' * (1.0 - COALESCE(mood_party, 0.0))',
          filter: 'voice_instrumental IS NOT NULL',
          params: const [],
        );
    }
  }
}

class _ChipSpec {
  final String confidenceExpr;
  final String filter;
  final List<Object?> params;
  const _ChipSpec({
    required this.confidenceExpr,
    required this.filter,
    required this.params,
  });
}
