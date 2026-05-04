import 'package:meta/meta.dart';

import 'cache_db.dart';

/// Persisted playlist record. Slice-6 LLM playlists hit `insertGenerated`
/// when the user taps Play on the result card; the Library Playlists
/// tab reads via `listAll`.
@immutable
class PlaylistRecord {
  final int id;
  final String title;
  final String? blurb;
  final String? prompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> trackPaths;

  const PlaylistRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.trackPaths,
    this.blurb,
    this.prompt,
  });

  int get trackCount => trackPaths.length;
}

class PlaylistsDao {
  PlaylistsDao(this._db);
  final CacheDb _db;

  /// Inserts a playlist + its tracks in a transaction. Returns the
  /// new playlists.id. trackPaths order is preserved as `position`.
  Future<int> insertGenerated({
    required String title,
    required List<String> trackPaths,
    String? blurb,
    String? prompt,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.writer.transaction<int>((txn) async {
      final id = await txn.insert('playlists', {
        'title': title,
        'blurb': blurb,
        'prompt': prompt,
        'created_at': now,
        'updated_at': now,
      });
      for (var i = 0; i < trackPaths.length; i++) {
        await txn.insert('playlist_tracks', {
          'playlist_id': id,
          'position': i,
          'track_path': trackPaths[i],
        });
      }
      return id;
    });
  }

  /// All playlists, newest first. Each record carries its track paths
  /// in original insertion order.
  Future<List<PlaylistRecord>> listAll() async {
    final rows = await _db.writer.rawQuery(
      'SELECT id, title, blurb, prompt, created_at, updated_at '
      'FROM playlists ORDER BY created_at DESC',
    );
    final out = <PlaylistRecord>[];
    for (final r in rows) {
      final id = r['id'] as int;
      final tracks = await _readTracks(id);
      out.add(_rowToRecord(r, tracks));
    }
    return out;
  }

  Future<PlaylistRecord?> getById(int id) async {
    final rows = await _db.writer.rawQuery(
      'SELECT id, title, blurb, prompt, created_at, updated_at '
      'FROM playlists WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final tracks = await _readTracks(id);
    return _rowToRecord(rows.first, tracks);
  }

  /// Cascade-deletes the row + its playlist_tracks (FK ON DELETE CASCADE).
  Future<int> deleteById(int id) async {
    return _db.writer.delete(
      'playlists',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<String>> _readTracks(int playlistId) async {
    final rows = await _db.writer.rawQuery(
      'SELECT track_path FROM playlist_tracks '
      'WHERE playlist_id = ? ORDER BY position ASC',
      [playlistId],
    );
    return [for (final r in rows) r['track_path'] as String];
  }

  static PlaylistRecord _rowToRecord(
    Map<String, Object?> r,
    List<String> tracks,
  ) {
    return PlaylistRecord(
      id: r['id'] as int,
      title: r['title'] as String,
      blurb: r['blurb'] as String?,
      prompt: r['prompt'] as String?,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      trackPaths: tracks,
    );
  }
}
