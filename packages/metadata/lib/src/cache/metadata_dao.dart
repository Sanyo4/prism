import 'package:sqflite_common/sqlite_api.dart';

/// Cache row TTLs.
///
/// Fixed values per slice 2 §7: 30 days for `lastfm_artist` and
/// `artist`, 365 days for everything else (release/recording/CAA, all
/// of which are immutable once a release MBID exists).
class CacheTtl {
  CacheTtl._();
  static const Duration thirtyDays = Duration(days: 30);
  static const Duration oneYear = Duration(days: 365);
}

/// One row from `metadata_cache`. Round-trips raw JSON; callers parse.
class MetadataCacheEntry {
  final String kind;
  final String mbid;
  final String payload; // raw upstream JSON (or '{}' when caching a miss)
  final int fetchedAt;
  final int expiresAt;

  const MetadataCacheEntry({
    required this.kind,
    required this.mbid,
    required this.payload,
    required this.fetchedAt,
    required this.expiresAt,
  });
}

/// One row from `track_meta`. `patchedAt == 0` indicates a "tried and
/// got nothing" outcome so we can de-prioritise it on re-scan.
class TrackMetaRow {
  final String path;
  final String? recordingMbid;
  final String? releaseMbid;
  final String? artistMbid;
  final int patchedAt;
  final int attemptCount;
  final String? lastError;

  const TrackMetaRow({
    required this.path,
    required this.recordingMbid,
    required this.releaseMbid,
    required this.artistMbid,
    required this.patchedAt,
    required this.attemptCount,
    required this.lastError,
  });
}

/// Thin DAO over `metadata_cache` and `track_meta`. Pure CRUD; the
/// repository on top adds policy (TTL choice, miss caching, etc.).
class MetadataDao {
  final Database _db;

  /// Clock injected so tests can pin "now" without monkey-patching the
  /// Dart VM clock; production passes `DateTime.now`.
  final DateTime Function() now;

  MetadataDao(this._db, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  // --- metadata_cache ----------------------------------------------------

  /// Reads a cache entry by (kind, mbid). Treats expired rows as
  /// absent — the row stays in the table until something overwrites
  /// it, but the API contract is "cache hit ⇔ unexpired row".
  Future<MetadataCacheEntry?> readCache(String kind, String mbid) async {
    final rows = await _db.query(
      'metadata_cache',
      where: 'kind = ? AND mbid = ?',
      whereArgs: [kind, mbid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final expiresAt = row['expires_at'] as int;
    if (expiresAt < now().millisecondsSinceEpoch) return null;
    return MetadataCacheEntry(
      kind: row['kind'] as String,
      mbid: row['mbid'] as String,
      payload: row['payload'] as String,
      fetchedAt: row['fetched_at'] as int,
      expiresAt: expiresAt,
    );
  }

  /// Upserts (kind, mbid) → payload with a TTL relative to *now*.
  Future<void> upsertCache({
    required String kind,
    required String mbid,
    required String payload,
    required Duration ttl,
  }) async {
    final n = now().millisecondsSinceEpoch;
    await _db.insert(
      'metadata_cache',
      {
        'kind': kind,
        'mbid': mbid,
        'payload': payload,
        'fetched_at': n,
        'expires_at': n + ttl.inMilliseconds,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- track_meta --------------------------------------------------------

  Future<TrackMetaRow?> readTrackMeta(String path) async {
    final rows = await _db.query(
      'track_meta',
      where: 'path = ?',
      whereArgs: [path],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return TrackMetaRow(
      path: r['path'] as String,
      recordingMbid: r['recording_mbid'] as String?,
      releaseMbid: r['release_mbid'] as String?,
      artistMbid: r['artist_mbid'] as String?,
      patchedAt: r['patched_at'] as int,
      attemptCount: r['attempt_count'] as int,
      lastError: r['last_error'] as String?,
    );
  }

  /// Upsert a track_meta row. [patchedAt] = 0 indicates the backfill
  /// tried this track but produced an empty patch.
  Future<void> upsertTrackMeta({
    required String path,
    String? recordingMbid,
    String? releaseMbid,
    String? artistMbid,
    required int patchedAt,
    required int attemptCount,
    String? lastError,
  }) async {
    await _db.insert(
      'track_meta',
      {
        'path': path,
        'recording_mbid': recordingMbid,
        'release_mbid': releaseMbid,
        'artist_mbid': artistMbid,
        'patched_at': patchedAt,
        'attempt_count': attemptCount,
        'last_error': lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Wipes both tables in one transaction. Used by Settings →
  /// "Clear metadata cache".
  Future<void> clearAll() async {
    await _db.transaction((txn) async {
      await txn.delete('metadata_cache');
      await txn.delete('track_meta');
    });
  }
}
