import 'package:sqflite_common/sqflite.dart';

// Vec0Loader is NOT imported here — vec0 DDL is no longer run inside
// any migration step. The import is kept as a comment so the next
// engineer knows the removal was deliberate, not accidental.
// import 'vec_loader.dart';

/// Linear schema migrations for `cache.db`. Slice 4 ships v1; later
/// slices append numbered steps without rewriting old ones.
///
/// **Single source of DDL.** The body of v1 is the spec's DDL pasted
/// verbatim plus the slice-4 `ALTER TABLE` additions (status, play_count,
/// analyzer_models, etc.). Anything that needs an index goes here too —
/// the runtime never `CREATE INDEX IF NOT EXISTS`es from query helpers.
class Migrations {
  /// Schema version Prism's slice-4 build emits. Bump this in lockstep
  /// with a new migration step — never edit the old steps in place.
  static const int currentVersion = 3;

  /// Database `version` matches [currentVersion]. Hooked into
  /// `sqflite.openDatabase(version: Migrations.currentVersion, ...)`.
  static int get version => currentVersion;

  /// Apply every migration step needed to bring a database from
  /// [oldVersion] up to [Migrations.currentVersion]. The caller wraps
  /// the call in a transaction.
  static Future<void> upgrade(
    DatabaseExecutor txn, {
    required int oldVersion,
    required int newVersion,
  }) async {
    if (oldVersion < 1 && newVersion >= 1) await _v1(txn);
    if (oldVersion < 2 && newVersion >= 2) await _v2(txn);
    if (oldVersion < 3 && newVersion >= 3) await _v3(txn);
  }

  /// Initial creation path for a brand-new database. Same DDL as
  /// stepping up from oldVersion=0 — kept as a separate entrypoint so
  /// `sqflite.onCreate` doesn't have to fake an `oldVersion` value.
  static Future<void> create(DatabaseExecutor txn) async {
    await _v1(txn);
    await _v2(txn);
    await _v3(txn);
  }

  static Future<void> _v3(DatabaseExecutor txn) async {
    await txn.execute('''
      CREATE TABLE tracks_cache (
        path                TEXT PRIMARY KEY,
        mtime_ms            INTEGER NOT NULL,
        title               TEXT,
        artist              TEXT,
        album_artist        TEXT,
        album               TEXT,
        genre               TEXT,
        track_no            INTEGER,
        disc_no             INTEGER,
        year                INTEGER,
        duration_ms         INTEGER,
        replaygain_track_db REAL,
        replaygain_album_db REAL,
        scanned_at          INTEGER NOT NULL
      )
    ''');
    await txn.execute(
      'CREATE INDEX tracks_cache_album ON tracks_cache(album)',
    );
    await txn.execute(
      'CREATE INDEX tracks_cache_artist ON tracks_cache(artist)',
    );
  }

  static Future<void> _v2(DatabaseExecutor txn) async {
    await txn.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        blurb TEXT,
        prompt TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await txn.execute('''
      CREATE TABLE playlist_tracks (
        playlist_id INTEGER NOT NULL,
        position INTEGER NOT NULL,
        track_path TEXT NOT NULL,
        PRIMARY KEY (playlist_id, position),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
      )
    ''');
    await txn.execute(
      'CREATE INDEX playlist_tracks_path ON playlist_tracks(track_path)',
    );
  }

  static Future<void> _v1(DatabaseExecutor txn) async {
    // Spec DDL (docs/spec.md "SQLite schema"). Field order locked.
    await txn.execute('''
      CREATE TABLE tracks (
        id                  INTEGER PRIMARY KEY,
        path                TEXT UNIQUE NOT NULL,
        audio_sha1          TEXT NOT NULL,
        sidecar_path        TEXT,
        sidecar_mtime       INTEGER,

        title               TEXT,
        artist              TEXT,
        album_artist        TEXT,
        album               TEXT,
        track_no            INTEGER,
        disc_no             INTEGER,
        year                INTEGER,
        genre               TEXT,
        duration_sec        REAL,

        bpm                 REAL,
        key                 TEXT,
        loudness_lufs       REAL,
        replaygain_track_db REAL,
        replaygain_album_db REAL,
        danceability        REAL,
        voice_instrumental  REAL,

        mood_happy          REAL,
        mood_sad            REAL,
        mood_aggressive     REAL,
        mood_relaxed        REAL,
        mood_party          REAL,

        added_at            INTEGER,

        -- slice-4 additions (same v1 migration, plan §7)
        status              TEXT NOT NULL DEFAULT 'ready',
        analyzer_models     TEXT,
        schema_version      INTEGER,
        play_count          INTEGER NOT NULL DEFAULT 0,
        last_played_at      INTEGER
      )
    ''');
    await txn.execute('CREATE INDEX tracks_artist ON tracks(artist)');
    await txn.execute('CREATE INDEX tracks_album  ON tracks(album)');
    await txn.execute('CREATE INDEX tracks_genre  ON tracks(genre)');
    await txn.execute('CREATE INDEX tracks_status ON tracks(status)');
    await txn.execute('CREATE INDEX tracks_mood_happy   ON tracks(mood_happy)');
    await txn.execute('CREATE INDEX tracks_mood_sad     ON tracks(mood_sad)');
    await txn.execute('CREATE INDEX tracks_mood_relaxed ON tracks(mood_relaxed)');
    await txn.execute('CREATE INDEX tracks_mood_party   ON tracks(mood_party)');
    await txn.execute('CREATE INDEX tracks_bpm          ON tracks(bpm)');

    // Slice-10b §A1' — vec0 DDL is NOT created inside the migration. On
    // Android, sqflite uses the system SQLite which doesn't see
    // extensions registered via package:sqlite3.ensureExtensionLoaded.
    // Running the vec0 DDL inside the migration would crash open() on
    // Android even when the .so was 'loaded' on the FFI side. Instead,
    // CacheDb.open attempts the DDL OUTSIDE the migration, after the
    // writer is committed, in its own try-catch. Failure sets
    // Vec0Loader.loadFailed = true and the app continues in degraded
    // mode (mood/vibe/library work; radio unavailable).
  }
}

/// Slice-10b §A1' — vec0 virtual-table DDL extracted from the
/// migration so it can be called OUTSIDE the migration step, in its
/// own try-catch, after the writer is open. Uses `IF NOT EXISTS` so
/// the call is idempotent across cold launches and re-opens.
///
/// Called by [CacheDb.open] after the writer handle is committed and
/// before the FFI reader is opened. Failure there sets
/// [Vec0Loader.loadFailed] without throwing; the app degrades
/// gracefully (mood/vibe/library OK; radio unavailable).
Future<void> createVec0Table(DatabaseExecutor txn) async {
  await txn.execute('''
    CREATE VIRTUAL TABLE IF NOT EXISTS track_embeddings USING vec0(
      track_id  INTEGER PRIMARY KEY,
      embedding FLOAT[1280]
    )
  ''');
}
