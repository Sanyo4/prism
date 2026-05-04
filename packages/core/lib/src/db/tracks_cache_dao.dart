import 'package:sqflite_common/sqflite.dart' show ConflictAlgorithm;

import '../models/track.dart';
import 'cache_db.dart';

/// Slice-10b §D2 — persisted track scan cache. The Music dir scan
/// (slice-1 LibraryScanner) writes here once per change; cold starts
/// read from here directly so the UI doesn't block on FS I/O.
///
/// Keyed on `path`. `mtime_ms` is the FS mtime — diffing the live
/// scan against this map reveals new / changed / removed paths.
class TracksCacheDao {
  TracksCacheDao(this._db);
  final CacheDb _db;

  /// All cached tracks. Used as the warm-start payload by
  /// `tracksProvider` (D3).
  Future<List<Track>> readAll() async {
    final rows = await _db.writer.rawQuery(
      'SELECT path, mtime_ms, title, artist, album_artist, album, '
      'genre, track_no, disc_no, year, duration_ms, '
      'replaygain_track_db, replaygain_album_db FROM tracks_cache '
      'ORDER BY artist, album, disc_no, track_no',
    );
    return [for (final r in rows) _rowToTrack(r)];
  }

  /// Map `path → mtime_ms` for the live-scan diff (D3). Cheap;
  /// reads only two columns.
  Future<Map<String, int>> readPathMtimes() async {
    final rows = await _db.writer.rawQuery(
      'SELECT path, mtime_ms FROM tracks_cache',
    );
    return {
      for (final r in rows)
        (r['path'] as String): (r['mtime_ms'] as int),
    };
  }

  /// Upsert a single track row. Caller must have a non-null
  /// `mtime_ms` (i.e. a fresh FS scan reading); rows from other
  /// sources should not flow here.
  Future<void> upsert(Track track) async {
    if (track.mtimeMs == 0) {
      throw ArgumentError(
        'TracksCacheDao.upsert requires non-zero mtimeMs; got 0 for '
        '${track.path}',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.writer.insert(
      'tracks_cache',
      {
        'path': track.path,
        'mtime_ms': track.mtimeMs,
        'title': track.title,
        'artist': track.artist,
        'album_artist': track.albumArtist,
        'album': track.album,
        'genre': track.genre,
        'track_no': track.trackNo,
        'disc_no': track.discNo,
        'year': track.year,
        'duration_ms': track.duration?.inMilliseconds,
        'replaygain_track_db': track.replayGainTrackDb,
        'replaygain_album_db': track.replayGainAlbumDb,
        'scanned_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Batch upsert in a single transaction. Cheaper than N upserts
  /// when the live-scan diff yields many new/changed rows on first
  /// run after install.
  Future<void> upsertAll(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.writer.transaction((txn) async {
      for (final track in tracks) {
        if (track.mtimeMs == 0) continue;
        await txn.insert(
          'tracks_cache',
          {
            'path': track.path,
            'mtime_ms': track.mtimeMs,
            'title': track.title,
            'artist': track.artist,
            'album_artist': track.albumArtist,
            'album': track.album,
            'genre': track.genre,
            'track_no': track.trackNo,
            'disc_no': track.discNo,
            'year': track.year,
            'duration_ms': track.duration?.inMilliseconds,
            'replaygain_track_db': track.replayGainTrackDb,
            'replaygain_album_db': track.replayGainAlbumDb,
            'scanned_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Deletes any cached rows whose `path` is not in [livePaths].
  /// Returns the number of rows removed. Used post-scan to prune
  /// rows for files the user deleted from the Music dir.
  Future<int> deletePathsNotIn(Set<String> livePaths) async {
    if (livePaths.isEmpty) {
      // If there's nothing live, blow the whole cache away.
      return _db.writer.delete('tracks_cache');
    }
    // SQLite has a parameter limit (~999); chunk the IN clause.
    final cached = await readPathMtimes();
    final stale = cached.keys.where((p) => !livePaths.contains(p)).toList();
    if (stale.isEmpty) return 0;
    var removed = 0;
    for (var i = 0; i < stale.length; i += 500) {
      final chunk = stale.sublist(
        i,
        (i + 500).clamp(0, stale.length),
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      removed += await _db.writer.rawDelete(
        'DELETE FROM tracks_cache WHERE path IN ($placeholders)',
        chunk,
      );
    }
    return removed;
  }

  static Track _rowToTrack(Map<String, Object?> r) {
    return Track(
      path: r['path'] as String,
      mtimeMs: r['mtime_ms'] as int,
      title: r['title'] as String?,
      artist: r['artist'] as String?,
      albumArtist: r['album_artist'] as String?,
      album: r['album'] as String?,
      genre: r['genre'] as String?,
      trackNo: r['track_no'] as int?,
      discNo: r['disc_no'] as int?,
      year: r['year'] as int?,
      duration: (r['duration_ms'] as int?) == null
          ? null
          : Duration(milliseconds: r['duration_ms'] as int),
      replayGainTrackDb: (r['replaygain_track_db'] as num?)?.toDouble(),
      replayGainAlbumDb: (r['replaygain_album_db'] as num?)?.toDouble(),
    );
  }
}
