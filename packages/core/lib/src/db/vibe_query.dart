import 'cache_db.dart';

/// Five classifier-native mood chips for the Vibe browse surface.
/// Distinct from [MoodChip] — Vibe is the raw classifier output (no
/// "Chill" / "Focus" derived chips), suitable for crate-digging.
enum VibeMoodChip { happy, sad, aggressive, relaxed, party }

/// Tempo bands rendered as a segmented control under the Vibe chips.
/// `null` band == "any tempo" (the segmented control's de-selected
/// state).
enum TempoBand { calm, mid, hot }

/// One row returned from a Vibe query. Same fields the mood-row
/// surface needs, but no rank score — Vibe sorts purely by SQL on
/// `mood_<chip>`.
class VibeTrack {
  final int trackId;
  final String path;
  final String? title;
  final String? artist;
  final String? album;
  final double moodScore;
  final double? bpm;

  const VibeTrack({
    required this.trackId,
    required this.path,
    required this.moodScore,
    required this.bpm,
    this.title,
    this.artist,
    this.album,
  });
}

class VibeQuery {
  VibeQuery(this._db);
  final CacheDb _db;

  /// Minimum classifier confidence to surface a track on a Vibe chip.
  /// Slice 4 hard-codes 0.3; slice 5 may expose this as a "Strict"
  /// toggle in Settings.
  static const double _minMoodFloor = 0.3;

  /// Returns up to [limit] tracks matching [mood] (and optionally
  /// [band]), ordered by `mood_<chip>` descending, with
  /// `status='ready'` mandatory.
  ///
  /// We apply a minimum mood-confidence floor of `0.3` ([_minMoodFloor])
  /// so an empty Vibe panel renders for libraries with no plausible
  /// matches instead of a long list of borderline-zero rows. The
  /// floor matches the §11.5 spec ("every row `mood_relaxed > 0.3`")
  /// — verification depends on it.
  Future<List<VibeTrack>> run({
    required VibeMoodChip mood,
    TempoBand? band,
    int limit = 200,
  }) async {
    final col = _moodColumn(mood);
    final whereParts = <String>[
      "status = 'ready'",
      '$col IS NOT NULL',
      '$col > $_minMoodFloor',
    ];
    if (band != null) {
      whereParts.add(_bandPredicate(band));
    }
    final sql = '''
      SELECT id, path, title, artist, album, $col AS mood_score, bpm
        FROM tracks
       WHERE ${whereParts.join(' AND ')}
       ORDER BY $col DESC
       LIMIT ?
    ''';
    final rows = await _db.writer.rawQuery(sql, [limit]);
    return [
      for (final r in rows)
        VibeTrack(
          trackId: r['id'] as int,
          path: r['path'] as String,
          title: r['title'] as String?,
          artist: r['artist'] as String?,
          album: r['album'] as String?,
          moodScore: (r['mood_score'] as num?)?.toDouble() ?? 0.0,
          bpm: (r['bpm'] as num?)?.toDouble(),
        ),
    ];
  }

  static String _moodColumn(VibeMoodChip chip) {
    switch (chip) {
      case VibeMoodChip.happy:
        return 'mood_happy';
      case VibeMoodChip.sad:
        return 'mood_sad';
      case VibeMoodChip.aggressive:
        return 'mood_aggressive';
      case VibeMoodChip.relaxed:
        return 'mood_relaxed';
      case VibeMoodChip.party:
        return 'mood_party';
    }
  }

  /// Tempo bands per §7: `calm < 90`, `mid 90..120`, `hot > 120`. The
  /// boundary inclusivity matches the plan exactly — 90 lands in
  /// `mid`, 120 lands in `mid`, 90.0001 still counts as `mid`.
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
