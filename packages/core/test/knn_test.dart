import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('knnByEmbedding', () {
    test('returns k rows in ascending distance order, seed excluded',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;

      // Seed 6 tracks at known distances. We'll seed_id = 1, with
      // synthetic embeddings of seeds 0, 5, 10, 50, 100, 500. The
      // closest non-seed should be seed=5 (5/1280 spacing).
      final seeds = [0, 5, 10, 50, 100, 500];
      final ids = <int>[];
      for (var i = 0; i < seeds.length; i++) {
        final id = await insertRawTrackRow(
          db.writer,
          path: '/t${seeds[i]}.flac',
          audioSha1: 'a${seeds[i]}'.padRight(40, 'x'),
          status: 'ready',
        );
        ids.add(id);
        await db.writer.execute(
          'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
          [id, embeddingBlob(syntheticEmbedding(seeds[i].toDouble()))],
        );
      }
      final seedRowId = ids[0]; // seed=0
      final hits = await db.knnByEmbedding(seedTrackId: seedRowId, k: 3);
      expect(hits, hasLength(3));
      // Seed itself excluded.
      expect(hits.every((h) => h.trackId != seedRowId), isTrue);
      // Ascending distances.
      for (var i = 0; i < hits.length - 1; i++) {
        expect(hits[i].distance, lessThanOrEqualTo(hits[i + 1].distance));
      }
      // The first hit must be the closest neighbor (seed=5, mapped to
      // ids[1]).
      expect(hits.first.trackId, ids[1]);
    });

    test('seed near-duplicate sits at distance ≈ 0', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final base = syntheticEmbedding(123);
      final near = List<double>.from(base);
      // Tiny perturbation in one dimension.
      near[7] += 1e-5;
      final seedId = await insertRawTrackRow(
        db.writer,
        path: '/seed.flac',
        audioSha1: 'a' * 40,
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [seedId, embeddingBlob(base)],
      );
      final nearId = await insertRawTrackRow(
        db.writer,
        path: '/near.flac',
        audioSha1: 'b' * 40,
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [nearId, embeddingBlob(near)],
      );
      // Distractor.
      final distractorId = await insertRawTrackRow(
        db.writer,
        path: '/far.flac',
        audioSha1: 'c' * 40,
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [distractorId, embeddingBlob(syntheticEmbedding(900))],
      );
      final hits = await db.knnByEmbedding(seedTrackId: seedId, k: 5);
      expect(hits, isNotEmpty);
      expect(hits.first.trackId, nearId);
      expect(hits.first.distance, lessThan(0.01));
    });

    test('non-ready rows are filtered out', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final seedId = await insertRawTrackRow(
        db.writer,
        path: '/seed.flac',
        audioSha1: 'a' * 40,
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [seedId, embeddingBlob(syntheticEmbedding(0))],
      );
      // analysis_pending row with a near-duplicate embedding — must
      // be filtered out.
      final pendingId = await insertRawTrackRow(
        db.writer,
        path: '/pending.flac',
        audioSha1: 'b' * 40,
        status: 'analysis_pending',
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [pendingId, embeddingBlob(syntheticEmbedding(0.001))],
      );
      // Far-but-ready row.
      final readyId = await insertRawTrackRow(
        db.writer,
        path: '/ready.flac',
        audioSha1: 'c' * 40,
      );
      await db.writer.execute(
        'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
        [readyId, embeddingBlob(syntheticEmbedding(500))],
      );
      final hits = await db.knnByEmbedding(seedTrackId: seedId, k: 5);
      expect(hits.map((h) => h.trackId), [readyId]);
    });

    test('no embedding for seed → empty result, no throw', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final id = await insertRawTrackRow(
        db.writer,
        path: '/no-emb.flac',
        audioSha1: 'a' * 40,
      );
      final hits = await db.knnByEmbedding(seedTrackId: id, k: 5);
      expect(hits, isEmpty);
    });
  });
}
