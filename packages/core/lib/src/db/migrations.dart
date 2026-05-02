import 'package:sqflite_common/sqflite.dart';

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
  static const int currentVersion = 1;

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
    if (oldVersion < 1 && newVersion >= 1) {
      await _v1(txn);
    }
    // Future steps:
    // if (oldVersion < 2 && newVersion >= 2) await _v2(txn);
  }

  /// Initial creation path for a brand-new database. Same DDL as
  /// stepping up from oldVersion=0 — kept as a separate entrypoint so
  /// `sqflite.onCreate` doesn't have to fake an `oldVersion` value.
  static Future<void> create(DatabaseExecutor txn) async {
    await _v1(txn);
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

    // The vec0 virtual table goes here too; vec0 must be loaded into
    // the FFI handle (and registered process-wide via
    // sqlite3.ensureExtensionLoaded) *before* this DDL runs. CacheDb
    // sequences that for us.
    await txn.execute('''
      CREATE VIRTUAL TABLE track_embeddings USING vec0(
        track_id  INTEGER PRIMARY KEY,
        embedding FLOAT[1280]
      )
    ''');
  }
}
