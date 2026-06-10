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

  /// Returns the deck under the chip set + tempo band.
  ///
  /// Three branches:
  /// 1. **True-Shuffle ON, zero chips** — uniformly-random `status='ready'`
  ///    deck (with optional tempo band).
  /// 2. **True-Shuffle ON, non-empty chips** *(slice-11 §B2)* — chip
  ///    filter still applies, but rows are randomised instead of
  ///    score-ranked. This closes the slice-10b D bypass bug where
  ///    True-Shuffle dropped the chip filter entirely.
  /// 3. **True-Shuffle OFF** — chip-aware filter / bias mode (existing
  ///    slice-10 §2.2 behaviour).
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

    if (chips.isEmpty) {
      // Branch 1: zero chips. trueShuffle is implied — there's no chip
      // signal to rank by, so we return a uniformly-random ready set.
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

    // Build the chip filter clause. Reused by both True-Shuffle ON and
    // OFF branches below — slice-11 §B2 invariant: chip filter applies
    // identically in both, only the ORDER BY differs.
    final chipExprs =
        chips.map(MoodQuery.chipExpression).toList(growable: false);
    final scoreExpr = chipExprs.length == 1
        ? chipExprs.first
        : '(${chipExprs.join(' + ')})';
    final chipWhereParts = List<String>.from(whereParts)
      ..add(
        chipExprs.length == 1
            ? '($scoreExpr) > $singleChipFloor'
            : '($scoreExpr) > 0',
      );

    if (trueShuffle) {
      // Branch 2: chips constrain the set, ORDER BY RANDOM() shuffles
      // the order. score is the chip-expression value so consumers
      // (e.g. trailing widgets) can still surface intensity if needed.
      final sql = '''
        SELECT id, path, title, artist, album, bpm, added_at,
               ($scoreExpr) AS score
          FROM tracks
         WHERE ${chipWhereParts.join(' AND ')}
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
            score: (r['score'] as num?)?.toDouble() ?? 0.0,
            bpm: (r['bpm'] as num?)?.toDouble(),
          ),
      ];
    }

    // Branch 3: True-Shuffle OFF, chips non-empty. Slice-10 §2.2
    // chip-aware filter / bias mode. ORDER BY score then re-rank in
    // Dart by recency to mirror MoodQuery's two-phase rank.
    final sql = '''
      SELECT id, path, title, artist, album, bpm, added_at,
             ($scoreExpr) AS score
        FROM tracks
       WHERE ${chipWhereParts.join(' AND ')}
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
