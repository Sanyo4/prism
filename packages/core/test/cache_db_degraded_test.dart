import 'dart:io';
import 'dart:typed_data';

import 'package:prism_core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('CacheDb degraded mode (vec0 load failure)', () {
    test('open succeeds with bad vec0 path; loadFailed=true; '
        'tracks table exists; track_embeddings absent', () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('prism-degraded-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      // Reset state in case other tests left it dirty.
      Vec0Loader.loadFailed = false;
      Vec0Loader.loadFailureMessage = null;
      final db = await CacheDb.open(
        factory: factory,
        path: '${dir.path}/cache.db',
        vec0Path: '/nonexistent/path/to/vec0.so',
      );
      addTearDown(db.close);

      expect(Vec0Loader.loadFailed, isTrue);
      expect(Vec0Loader.loadFailureMessage, isNotNull);

      // The tracks table should still exist (migration ran).
      final tablesRows = await db.writer.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        'ORDER BY name',
      );
      final tableNames = tablesRows.map((r) => r['name'] as String).toList();
      expect(tableNames, contains('tracks'));
      expect(tableNames, isNot(contains('track_embeddings')),
          reason: 'vec0 DDL must be skipped on load failure');
    });

    test('mood query still works when vec0 failed to load', () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('prism-degraded-mood-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      Vec0Loader.loadFailed = false;
      Vec0Loader.loadFailureMessage = null;
      final db = await CacheDb.open(
        factory: factory,
        path: '${dir.path}/cache.db',
        vec0Path: '/nonexistent/path/to/vec0.so',
      );
      addTearDown(db.close);

      // Insert a row with mood data.
      await db.writer.insert('tracks', {
        'path': '/h.flac',
        'audio_sha1': 'h' * 40,
        'status': 'ready',
        'mood_happy': 0.9,
        'mood_sad': 0.1,
        'mood_aggressive': 0.0,
        'mood_relaxed': 0.5,
        'mood_party': 0.2,
        'voice_instrumental': 0.5,
        'bpm': 120.0,
        'danceability': 0.6,
      });

      final results = await db.moods.run(MoodChip.happy, limit: 10);
      expect(results, isNotEmpty);
      expect(results.first.path, '/h.flac');
    });

    test('PlaylistRepoImpl returns empty kNN / null means when load failed',
        () async {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;
      final dir = Directory.systemTemp.createTempSync('prism-degraded-knn-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      Vec0Loader.loadFailed = false;
      Vec0Loader.loadFailureMessage = null;
      final db = await CacheDb.open(
        factory: factory,
        path: '${dir.path}/cache.db',
        vec0Path: '/nonexistent/path/to/vec0.so',
      );
      addTearDown(db.close);

      final repo = PlaylistRepoImpl(db);

      final hits = await repo.knnByEmbedding(
        Float32List.fromList(List<double>.filled(1280, 0.0)),
      );
      expect(hits, isEmpty);

      final albumMean = await repo.meanEmbeddingForAlbum('any');
      expect(albumMean, isNull);

      final artistMean = await repo.meanEmbeddingForArtist('any');
      expect(artistMean, isNull);

      // embeddingOf throws StateError with the failure message.
      expect(
        () => repo.embeddingOf(1),
        throwsStateError,
      );
    });
  });
}
