import 'package:sqflite_common/sqflite.dart';
import 'package:sqlite3/sqlite3.dart' as ffi;

import 'knn.dart';
import 'migrations.dart';
import 'mood_query.dart';
import 'vec_loader.dart';
import 'vibe_query.dart';

/// Per-device disposable cache built by scanning sidecars. Pairs two
/// SQLite handles on the same file:
///
/// 1. **`sqflite` write handle** ([writer]) — async transactions for
///    upsert/reconcile. WAL is enabled in `onConfigure`.
/// 2. **`sqlite3` FFI read handle** ([reader]) — synchronous queries
///    that need the `vec0` virtual-table module (kNN hot path) and
///    don't want to fight sqflite's per-call serialisation.
///
/// `vec0` is registered process-wide via `Vec0Loader.ensureLoaded`
/// *before* either handle opens; sqflite picks it up automatically
/// when its internal connection pool spins up.
class CacheDb {
  CacheDb._({
    required this.writer,
    required this.reader,
    required this.path,
  });

  /// Filesystem path to the underlying `cache.db`. Same file used by
  /// both handles.
  final String path;

  /// Async write handle. Use through transactions.
  final Database writer;

  /// Synchronous FFI read handle. `vec0` MATCH queries go here.
  final ffi.Database reader;

  /// Open / create [path] using [factory] (sqflite for Android,
  /// sqflite_common_ffi for Linux + tests). [vec0Path] resolves the
  /// platform-specific `vec0.so` — pass [Vec0Loader.resolvePath] on
  /// Linux desktop, or a manually-copied asset path on Android.
  ///
  /// Idempotent: opening twice on the same path returns two
  /// independent `CacheDb` instances; the second `Vec0Loader.ensureLoaded`
  /// call is a no-op.
  static Future<CacheDb> open({
    required DatabaseFactory factory,
    required String path,
    required String vec0Path,
  }) async {
    // Register vec0 *before* opening anything: sqflite will reach for
    // the auto-extension list when its internal connection pool spins
    // up, and the FFI read handle obviously needs it too.
    Vec0Loader.ensureLoaded(vec0Path);

    final writer = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: Migrations.version,
        onConfigure: (db) async {
          // WAL lets the FFI reader stay lock-free while writes run.
          // Mandatory per slice-4 §10 risk 12.
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await Migrations.create(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await Migrations.upgrade(
            db,
            oldVersion: oldVersion,
            newVersion: newVersion,
          );
        },
      ),
    );

    // Read handle: `package:sqlite3` FFI. Same file, opened
    // independently. WAL means cross-handle reads see committed
    // writes without explicit checkpointing.
    final reader = ffi.sqlite3.open(path);

    return CacheDb._(writer: writer, reader: reader, path: path);
  }

  /// Mood-row provider for the Home surface (5 chips: Happy / Sad /
  /// Chill / Energetic / Focus). Constructed lazily — the dependency
  /// is the writer (for `play_count`/`last_played_at` updates) +
  /// reader (for the SQL itself).
  MoodQuery get moods => MoodQuery(this);

  /// Vibe browse — classifier-native chips + tempo band.
  VibeQuery get vibes => VibeQuery(this);

  /// kNN over [track_embeddings]. Returns a list ordered by ascending
  /// L2 distance with the seed excluded. See [knnByEmbedding] in
  /// `knn.dart` for the implementation.
  Future<List<KnnHit>> knnByEmbedding({
    required int seedTrackId,
    int k = 25,
  }) =>
      runKnnByEmbedding(this, seedTrackId: seedTrackId, k: k);

  /// Releases both handles. Safe to call multiple times — the second
  /// call is a no-op (sqflite/sqlite3 both swallow double-close).
  Future<void> close() async {
    try {
      reader.dispose();
    } catch (_) {
      // Ignore: we may have closed already, or sqlite3 may have
      // already torn the handle down via finalisation. The error
      // surface here is identical either way.
    }
    await writer.close();
  }
}
