import 'dart:io';

import 'package:prism_core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('CacheDb.open with vec0 DDL outside migration', () {
    test(
      'open succeeds when vec0 .so loads — track_embeddings exists',
      () async {
        sqfliteFfiInit();
        final factory = databaseFactoryFfi;
        final dir = Directory.systemTemp.createTempSync('prism-vec0-ok-');
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        });
        // Reset state in case other tests left it dirty.
        Vec0Loader.loadFailed = false;
        Vec0Loader.loadFailureMessage = null;

        final vec0Path = resolveLinuxVec0Path();
        final db = await CacheDb.open(
          factory: factory,
          path: '${dir.path}/cache.db',
          vec0Path: vec0Path,
        );
        addTearDown(db.close);

        expect(Vec0Loader.loadFailed, isFalse);

        final tables = await db.writer.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          'ORDER BY name',
        );
        final names = tables.map((r) => r['name'] as String).toList();
        expect(names, contains('tracks'),
            reason: 'tracks table must always be created by migration');
        expect(names, contains('track_embeddings'),
            reason: 'vec0 DDL should succeed when .so is loaded correctly');
      },
    );

    test(
      'open succeeds when vec0 .so is missing — track_embeddings absent, '
      'loadFailed=true',
      () async {
        sqfliteFfiInit();
        final factory = databaseFactoryFfi;
        final dir = Directory.systemTemp.createTempSync('prism-vec0-bad-');
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        });
        Vec0Loader.loadFailed = false;
        Vec0Loader.loadFailureMessage = null;

        // Point at a path that does not exist so ensureLoaded fails at
        // the DynamicLibrary.open stage — simulates a missing .so on any
        // platform (including Android when the asset copy failed).
        final db = await CacheDb.open(
          factory: factory,
          path: '${dir.path}/cache.db',
          vec0Path: '/nonexistent/path/to/vec0.so',
        );
        addTearDown(db.close);

        expect(Vec0Loader.loadFailed, isTrue,
            reason: 'ensureLoaded should set loadFailed for a missing .so');

        final tables = await db.writer.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          'ORDER BY name',
        );
        final names = tables.map((r) => r['name'] as String).toList();
        expect(names, contains('tracks'),
            reason: 'main schema migration succeeds regardless of vec0');
        expect(names, isNot(contains('track_embeddings')),
            reason: 'vec0 DDL must be skipped when .so is absent');
      },
    );

    test(
      'idempotent: second open of same path does not crash — '
      'IF NOT EXISTS guard works',
      () async {
        // Verifies the §A1' IF NOT EXISTS guard on the post-open DDL:
        // opening a DB that already has track_embeddings must not throw.
        sqfliteFfiInit();
        final factory = databaseFactoryFfi;
        final dir = Directory.systemTemp.createTempSync('prism-vec0-idem-');
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        });
        Vec0Loader.loadFailed = false;
        Vec0Loader.loadFailureMessage = null;

        final vec0Path = resolveLinuxVec0Path();
        final dbPath = '${dir.path}/cache.db';

        // First open — creates the schema + track_embeddings.
        final db1 = await CacheDb.open(
          factory: factory,
          path: dbPath,
          vec0Path: vec0Path,
        );
        await db1.close();

        // Second open — IF NOT EXISTS should make the DDL a no-op, not
        // throw "table already exists".
        Vec0Loader.loadFailed = false;
        Vec0Loader.loadFailureMessage = null;
        // Reset the internal _loadedFrom cache so ensureLoaded re-runs.
        Vec0Loader.ensureLoaded(vec0Path); // re-register to ensure not stale

        final db2 = await CacheDb.open(
          factory: factory,
          path: dbPath,
          vec0Path: vec0Path,
        );
        addTearDown(db2.close);

        expect(Vec0Loader.loadFailed, isFalse);
        final tables = await db2.writer.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          'ORDER BY name',
        );
        final names = tables.map((r) => r['name'] as String).toList();
        expect(names, contains('tracks'));
        expect(names, contains('track_embeddings'));
      },
    );
  });
}
