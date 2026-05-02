import 'package:sqflite_common/sqlite_api.dart';

/// Schema-versioned bootstrap for `prism.db`. Slice 2 owns version 1
/// (metadata_cache + track_meta); slice 4 will bump to v2 and add the
/// `tracks` + `track_embeddings` tables.
///
/// `MetadataDb.open` is platform-agnostic — it takes a
/// `DatabaseFactory` from the caller. Apps inject `databaseFactoryFfi`
/// on Linux desktop and the default `databaseFactory` (the sqflite
/// plugin) on Android. Tests inject `databaseFactoryFfi` too. This
/// keeps `packages/metadata` Flutter-free.
class MetadataDb {
  /// Current schema version known to slice 2.
  static const int schemaVersion = 1;

  /// DDL for `metadata_cache`. Stores raw upstream JSON keyed by
  /// (kind, mbid). `kind` ∈ {`recording`, `release`, `artist`, `caa`,
  /// `lastfm_artist`}. `payload` carries the entire JSON so later
  /// slices can extract more fields without a re-fetch.
  static const String _ddlMetadataCache = '''
    CREATE TABLE metadata_cache (
      kind       TEXT NOT NULL,
      mbid       TEXT NOT NULL,
      payload    TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      PRIMARY KEY (kind, mbid)
    )
  ''';
  static const String _ddlMetadataCacheIndex =
      'CREATE INDEX metadata_cache_expires ON metadata_cache(expires_at)';

  /// DDL for `track_meta`. Path-keyed sidecar of "what MBIDs did the
  /// backfill resolve for this audio file"; lets us cheaply skip
  /// already-tried tracks and Settings → Clear wipe both tables in one
  /// transaction.
  static const String _ddlTrackMeta = '''
    CREATE TABLE track_meta (
      path           TEXT PRIMARY KEY,
      recording_mbid TEXT,
      release_mbid   TEXT,
      artist_mbid    TEXT,
      patched_at     INTEGER NOT NULL,
      attempt_count  INTEGER NOT NULL DEFAULT 0,
      last_error     TEXT
    )
  ''';
  static const String _ddlTrackMetaReleaseIdx =
      'CREATE INDEX track_meta_release ON track_meta(release_mbid)';
  static const String _ddlTrackMetaArtistIdx =
      'CREATE INDEX track_meta_artist ON track_meta(artist_mbid)';

  /// Opens (creating if absent) `prism.db` at [path] using the supplied
  /// [factory]. Slice 2 only knows v1; if the file already exists at a
  /// higher version (slice 4 ran first on the same device) we leave it
  /// alone — sqflite calls `onUpgrade` only when our requested version
  /// is higher, never on a downgrade.
  static Future<Database> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        // Slice 2 has no onUpgrade because there's no earlier version
        // to upgrade *from*. Slice 4 will add one keyed on v1 → v2.
      ),
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute(_ddlMetadataCache);
    await db.execute(_ddlMetadataCacheIndex);
    await db.execute(_ddlTrackMeta);
    await db.execute(_ddlTrackMetaReleaseIdx);
    await db.execute(_ddlTrackMetaArtistIdx);
  }
}
