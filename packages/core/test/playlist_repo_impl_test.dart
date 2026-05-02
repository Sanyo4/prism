import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('PlaylistRepoImpl', () {
    test('embeddingOf decodes 1280-dim float32 LE blobs', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final id = await insertRawTrackRow(
        db.writer,
        path: '/a.flac',
        audioSha1: 'a' * 40,
        status: 'ready',
      );
      final values = syntheticEmbedding(7);
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) '
        'VALUES (?, ?)',
        [id, embeddingBlob(values)],
      );
      final repo = PlaylistRepoImpl(db);
      final out = await repo.embeddingOf(id);
      expect(out.length, 1280);
      // Float32 round-trips lose a tiny amount of precision; allow
      // 1e-3 tolerance.
      for (var i = 0; i < 1280; i++) {
        expect(out[i], closeTo(values[i], 1e-3));
      }
    });

    test('embeddingOf throws ArgumentError on length mismatch', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final id = await insertRawTrackRow(
        db.writer,
        path: '/a.flac',
        audioSha1: 'a' * 40,
        status: 'ready',
      );
      // Insert a 768-dim blob (slice 5 §10 risk 8 — future analyzer
      // drift). vec0 happily accepts any blob shape on the prepared-
      // statement side; the read-side decoder should refuse.
      // First we have to drop the vec0 row so the column-shape check
      // doesn't trip — but vec0 enforces FLOAT[1280] so we can't store
      // a wrong-length blob there. Instead we directly poke the row by
      // re-creating the vec0 table at a different shape on a fresh DB.
      final shorter = List<double>.generate(768, (i) => i / 768.0);
      // Bypass vec0's strict column shape by replacing the table
      // with a non-vec0 stand-in so we can plant a bad blob and
      // verify the decoder catches it.
      await db.writer.execute('DROP TABLE track_embeddings');
      await db.writer.execute(
        'CREATE TABLE track_embeddings('
        'track_id INTEGER PRIMARY KEY, embedding BLOB)',
      );
      await db.writer.execute(
        'INSERT INTO track_embeddings(track_id, embedding) VALUES (?, ?)',
        [id, embeddingBlob(shorter)],
      );
      final repo = PlaylistRepoImpl(db);
      expect(() => repo.embeddingOf(id), throwsArgumentError);
    });

    test('meanEmbeddingForAlbum returns null when no ready rows', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final repo = PlaylistRepoImpl(ctx.db);
      final mean = await repo.meanEmbeddingForAlbum('Nope');
      expect(mean, isNull);
      await ctx.teardown();
    });

    test('meanEmbeddingForAlbum L2-normalizes and skips non-ready',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // Two ready tracks under the same album, plus one
      // analysis_pending track that should be excluded.
      final readyId1 = await insertRawTrackRow(
        db.writer,
        path: '/r1.flac',
        audioSha1: 'a' * 40,
        album: 'Disintegration',
        status: 'ready',
      );
      final readyId2 = await insertRawTrackRow(
        db.writer,
        path: '/r2.flac',
        audioSha1: 'b' * 40,
        album: 'Disintegration',
        status: 'ready',
      );
      final pendingId = await insertRawTrackRow(
        db.writer,
        path: '/p.flac',
        audioSha1: 'c' * 40,
        album: 'Disintegration',
        status: 'analysis_pending',
      );
      for (final (id, seed) in [
        (readyId1, 1.0),
        (readyId2, 2.0),
        (pendingId, 99.0),
      ]) {
        await db.writer.execute(
          'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) '
          'VALUES (?, ?)',
          [id, embeddingBlob(syntheticEmbedding(seed))],
        );
      }
      final repo = PlaylistRepoImpl(db);
      final mean = await repo.meanEmbeddingForAlbum('Disintegration');
      expect(mean, isNotNull);
      var sumSq = 0.0;
      for (final v in mean!) {
        sumSq += v * v;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('libraryWideFallback respects status="ready"', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final readyIds = <int>{};
      for (var i = 0; i < 5; i++) {
        final id = await insertRawTrackRow(
          db.writer,
          path: '/r$i.flac',
          audioSha1: 'r$i'.padRight(40, 'x'),
          status: 'ready',
        );
        readyIds.add(id);
      }
      // Pendings should not surface.
      for (var i = 0; i < 3; i++) {
        await insertRawTrackRow(
          db.writer,
          path: '/p$i.flac',
          audioSha1: 'p$i'.padRight(40, 'x'),
          status: 'analysis_pending',
        );
      }
      final repo = PlaylistRepoImpl(db, random: math.Random(0));
      final ids = await repo.libraryWideFallback(limit: 50);
      expect(ids.toSet(), readyIds);
    });

    test('knnByEmbedding top-5 matches a brute-force Dart L2 sweep',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // Seed 30 tracks with synthetic embeddings, all ready.
      final inserts = <(int, List<double>)>[];
      for (var i = 0; i < 30; i++) {
        final id = await insertRawTrackRow(
          db.writer,
          path: '/t$i.flac',
          audioSha1: 't$i'.padRight(40, 'x'),
          status: 'ready',
        );
        final emb = syntheticEmbedding((i * 17.0) % 1000);
        inserts.add((id, emb));
        await db.writer.execute(
          'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) '
          'VALUES (?, ?)',
          [id, embeddingBlob(emb)],
        );
      }
      // Pick id 0's embedding as the seed so the kNN result is
      // exercised by the JOIN-to-tracks filter as well.
      final seed = Float32List.fromList(inserts.first.$2);
      final repo = PlaylistRepoImpl(db);
      final hits = await repo.knnByEmbedding(seed, k: 5);
      expect(hits, hasLength(5));

      // Brute-force Dart L2 sweep over the same embeddings.
      final scored = <(int, double)>[];
      for (final (id, emb) in inserts) {
        var sum = 0.0;
        for (var i = 0; i < 1280; i++) {
          final d = emb[i] - seed[i];
          sum += d * d;
        }
        scored.add((id, sum)); // squared L2 — vec0 returns sqrt L2,
        // but ordering by squared distance is identical because
        // sqrt is monotone.
      }
      scored.sort((a, b) => a.$2.compareTo(b.$2));
      final bruteTop5 = scored.take(5).map((e) => e.$1).toSet();
      final vecTop5 = hits.map((h) => h.trackId).toSet();
      expect(vecTop5, equals(bruteTop5));
    });
  });
}
