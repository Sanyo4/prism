import 'cache_db.dart';
import 'mood_query.dart';
import 'vibe_query.dart';

/// One row in the Songs-tab shuffle deck. Distinct from
/// [VibeTrack]/[RankedTrack] so the consumer doesn't have to disambiguate
/// score semantics — `score` here is the steering rank (chip sum × recency).
class ShuffleTrack {
  /// `tracks.id` — same engine-id slice-5 keys on.
  final int trackId;
  final String path;
  final String? title;
  final String? artist;
  final String? album;

  /// Raw chip-expression sum (or single chip's value, or 0.0 in true-
  /// shuffle / zero-chip mode). Consumers that only need playback don't
  /// need this; the Songs tab sorts by it for the visible deck.
  final double score;

  final double? bpm;

  const ShuffleTrack({
    required this.trackId,
    required this.path,
    required this.score,
    this.title,
    this.artist,
    this.album,
    this.bpm,
  });
}

/// Builds the Songs-tab shuffle deck (slice 10 §2.2). Three modes,
/// selected by chip count and the True-Shuffle override. The chip
/// expressions are reused verbatim from [MoodQuery.chipExpression]; the
/// recency factor (Dart-side, see [recencyFactor]) is applied to the
/// bias and filter rankings to mirror `MoodQuery._rankScore`.
class VibeShuffleQuery {
  VibeShuffleQuery(this._db);
  final CacheDb _db;

  /// Hard upper bound on rows returned in any mode. Matches slice-4's
  /// `LIMIT 1000` precedent — keeps the visible list and the shuffle
  /// pool bounded on libraries with tens of thousands of tracks.
  static const int deckLimit = 1000;

  /// Confidence floor in single-chip filter mode. Matches §2.2 spec:
  /// "1 chip filter: WHERE `<chip.expr> > 0.5`".
  static const double singleChipFloor = 0.5;

  /// Returns the deck under the chip set + tempo band. When [trueShuffle]
  /// is true, [chips] is ignored and a uniformly-random deck of
  /// `status='ready'` rows is returned.
  Future<List<ShuffleTrack>> run({
    required Set<MoodChip> chips,
    required TempoBand? band,
    required bool trueShuffle,
    DateTime? now,
  }) async {
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final whereParts = <String>["status = 'ready'"];
    if (band != null) {
      whereParts.add(_bandPredicate(band));
    }

    if (trueShuffle || chips.isEmpty) {
      final sql = '''
        SELECT id, path, title, artist, album, bpm, added_at
          FROM tracks
         WHERE ${whereParts.join(' AND ')}
         ORDER BY RANDOM()
         LIMIT $deckLimit
      ''';
      final rows = await _db.writer.rawQuery(sql);
      return [
        for (final r in rows)
          ShuffleTrack(
            trackId: r['id'] as int,
            path: r['path'] as String,
            title: r['title'] as String?,
            artist: r['artist'] as String?,
            album: r['album'] as String?,
            score: 0.0,
            bpm: (r['bpm'] as num?)?.toDouble(),
          ),
      ];
    }

    // Build the score expression: single chip = its expression; many
    // chips = additive sum. Identical chip-expression strings either way.
    final chipExprs =
        chips.map(MoodQuery.chipExpression).toList(growable: false);
    final scoreExpr = chipExprs.length == 1
        ? chipExprs.first
        : '(${chipExprs.join(' + ')})';
    if (chipExprs.length == 1) {
      whereParts.add('($scoreExpr) > $singleChipFloor');
    } else {
      whereParts.add('($scoreExpr) > 0');
    }

    final sql = '''
      SELECT id, path, title, artist, album, bpm, added_at,
             ($scoreExpr) AS score
        FROM tracks
       WHERE ${whereParts.join(' AND ')}
       ORDER BY score DESC
       LIMIT $deckLimit
    ''';
    final rows = await _db.writer.rawQuery(sql);

    // Re-rank in Dart by score × recencyFactor — same pattern as
    // MoodQuery's two-phase rank.
    final ranked = <({ShuffleTrack track, double rank})>[];
    for (final r in rows) {
      final rawScore = (r['score'] as num?)?.toDouble() ?? 0.0;
      final addedAt = (r['added_at'] as int?) ?? nowMs;
      final recency = recencyFactor(addedAtMs: addedAt, nowMs: nowMs);
      final rank = rawScore * recency;
      ranked.add((
        track: ShuffleTrack(
          trackId: r['id'] as int,
          path: r['path'] as String,
          title: r['title'] as String?,
          artist: r['artist'] as String?,
          album: r['album'] as String?,
          score: rawScore,
          bpm: (r['bpm'] as num?)?.toDouble(),
        ),
        rank: rank,
      ));
    }
    ranked.sort((a, b) => b.rank.compareTo(a.rank));
    return [for (final e in ranked) e.track];
  }

  /// Reuses `VibeQuery._bandPredicate` semantics verbatim — calm < 90,
  /// mid 90..120 inclusive, hot > 120. Boundary inclusivity is the
  /// invariant slice-4 verification matrix locks.
  static String _bandPredicate(TempoBand band) {
    switch (band) {
      case TempoBand.calm:
        return 'bpm < 90';
      case TempoBand.mid:
        return 'bpm BETWEEN 90 AND 120';
      case TempoBand.hot:
        return 'bpm > 120';
    }
  }
}
