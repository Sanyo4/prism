import 'package:prism_core/core.dart';
// TODO(slice-6-integration): tighten to the playlist_engine barrel
// once Track A exports intent.dart.
import 'package:prism_playlist_engine/intent.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('TrackRepoImpl.candidatePoolByIntent', () {
    test('strict pool honours every predicate '
        '(sad>=0.5, bpm 70..110)', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // Seed: 3 sad+slow tracks (matches), 2 sad+fast (BPM out),
      // 2 happy+slow (mood out), 1 pending (status out).
      await insertRawTrackRow(
        db.writer,
        path: '/sad-slow-1.flac',
        audioSha1: 's1'.padRight(40, '0'),
        bpm: 80.0,
        moodSad: 0.7,
        moodRelaxed: 0.4,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/sad-slow-2.flac',
        audioSha1: 's2'.padRight(40, '0'),
        bpm: 95.0,
        moodSad: 0.6,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/sad-slow-3.flac',
        audioSha1: 's3'.padRight(40, '0'),
        bpm: 105.0,
        moodSad: 0.55,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/sad-fast-1.flac',
        audioSha1: 'sf1'.padRight(40, '0'),
        bpm: 150.0,
        moodSad: 0.8,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/sad-fast-2.flac',
        audioSha1: 'sf2'.padRight(40, '0'),
        bpm: 145.0,
        moodSad: 0.55,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/happy-slow-1.flac',
        audioSha1: 'h1'.padRight(40, '0'),
        bpm: 90.0,
        moodSad: 0.2,
        moodHappy: 0.8,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/happy-slow-2.flac',
        audioSha1: 'h2'.padRight(40, '0'),
        bpm: 85.0,
        moodSad: 0.15,
        moodHappy: 0.9,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/pending-sad.flac',
        audioSha1: 'p'.padRight(40, '0'),
        status: 'analysis_pending',
        bpm: 80.0,
        moodSad: 0.9,
      );

      final repo = TrackRepoImpl(db);
      final intent = Intent(
        moodTargets: const [MoodTarget(mood: 'sad', min: 0.5)],
        bpmRange: (70, 110),
        era: null,
        energyArc: EnergyArc.flat,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const [],
        narrative: 'sad slow vibe',
      );
      final ids = await repo.candidatePoolByIntent(intent);
      expect(ids.length, 3, reason: 'only the 3 sad+slow rows match');

      // Verify each surviving row satisfies the predicates.
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await db.writer.rawQuery(
        'SELECT bpm, mood_sad, status FROM tracks WHERE id IN ($placeholders)',
        ids,
      );
      for (final r in rows) {
        expect(r['status'], 'ready');
        expect((r['bpm'] as num).toDouble(), inInclusiveRange(70.0, 110.0));
        expect((r['mood_sad'] as num).toDouble(),
            greaterThanOrEqualTo(0.5));
      }
    });

    test('loose pool widens BPM ±10 and drops era — returns ≥1.5× '
        'strict count', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // 4 strict-eligible: bpm 70-110, sad>=0.5, era 1990-2000.
      for (var i = 0; i < 4; i++) {
        await insertRawTrackRow(
          db.writer,
          path: '/strict-$i.flac',
          audioSha1: 'strict$i'.padRight(40, '0'),
          bpm: 80.0 + i,
          year: 1995,
          moodSad: 0.6,
        );
      }
      // 4 only loose-eligible: bpm 60-65 (within ±10 of 70 lo) but
      // outside strict, plus year 1985 outside era (loose drops era).
      for (var i = 0; i < 4; i++) {
        await insertRawTrackRow(
          db.writer,
          path: '/loose-$i.flac',
          audioSha1: 'loose$i'.padRight(40, '0'),
          bpm: 62.0 + i,
          year: 1985,
          moodSad: 0.55,
        );
      }
      final repo = TrackRepoImpl(db);
      final intent = Intent(
        moodTargets: const [MoodTarget(mood: 'sad', min: 0.5)],
        bpmRange: (70, 110),
        era: (1990, 2000),
        energyArc: EnergyArc.flat,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const [],
        narrative: 'sad ninetiess',
      );
      final strict = await repo.candidatePoolByIntent(intent);
      final loose = await repo.candidatePoolByIntent(
        intent,
        relax: RelaxationLevel.loose,
      );
      expect(strict.length, 4);
      expect(
        loose.length,
        greaterThanOrEqualTo((strict.length * 1.5).ceil()),
        reason: 'loose drops era + widens BPM ±10 → +50% rows',
      );
    });

    test('veryLoose drops non-primary mood + doubles LIMIT '
        '— returns ≥3× strict count', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // 2 rows match the strict 2-mood AND filter (sad>=0.5 +
      // relaxed>=0.5).
      for (var i = 0; i < 2; i++) {
        await insertRawTrackRow(
          db.writer,
          path: '/both-$i.flac',
          audioSha1: 'both$i'.padRight(40, '0'),
          bpm: 95.0,
          moodSad: 0.7,
          moodRelaxed: 0.7,
        );
      }
      // 6 rows match only the primary mood (sad>=0.5) — visible
      // under veryLoose.
      for (var i = 0; i < 6; i++) {
        await insertRawTrackRow(
          db.writer,
          path: '/primary-$i.flac',
          audioSha1: 'p$i'.padRight(40, '0'),
          bpm: 95.0,
          moodSad: 0.7,
          moodRelaxed: 0.2,
        );
      }
      final repo = TrackRepoImpl(db);
      final intent = Intent(
        moodTargets: const [
          MoodTarget(mood: 'sad', min: 0.5),
          MoodTarget(mood: 'relaxed', min: 0.5),
        ],
        bpmRange: (70, 110),
        era: null,
        energyArc: EnergyArc.flat,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const [],
        narrative: 'sad and relaxed',
      );
      final strict = await repo.candidatePoolByIntent(intent);
      final veryLoose = await repo.candidatePoolByIntent(
        intent,
        relax: RelaxationLevel.veryLoose,
      );
      expect(strict.length, 2);
      expect(
        veryLoose.length,
        greaterThanOrEqualTo(strict.length * 3),
        reason: 'veryLoose keeps only sad>=0.5 → all 8 rows',
      );
    });

    test('orders by primary mood column DESC', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final ids = <int>[];
      for (final score in [0.55, 0.95, 0.75]) {
        ids.add(await insertRawTrackRow(
          db.writer,
          path: '/r-${score.toStringAsFixed(2)}.flac',
          audioSha1: 'r${score.toStringAsFixed(2)}'.padRight(40, '0'),
          moodSad: score,
        ));
      }
      final repo = TrackRepoImpl(db);
      final intent = Intent(
        moodTargets: const [MoodTarget(mood: 'sad', min: 0.5)],
        bpmRange: null,
        era: null,
        energyArc: EnergyArc.flat,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const [],
        narrative: 'sad',
      );
      final pool = await repo.candidatePoolByIntent(intent);
      // Highest mood_sad first → 0.95, 0.75, 0.55. The seeded ids
      // are in insertion order; we reorder by score to compare.
      final byScore = <(double, int)>[
        (0.55, ids[0]),
        (0.95, ids[1]),
        (0.75, ids[2]),
      ]..sort((a, b) => b.$1.compareTo(a.$1));
      expect(pool, [for (final s in byScore) s.$2]);
    });
  });

  group('TrackRepoImpl.meanEmbeddingForKeywords', () {
    test('returns 1280-dim L2-normalized vector for known keywords',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // 2 ready tracks high on `relaxed` (rainy/ambient → relaxed).
      for (var i = 0; i < 2; i++) {
        final id = await insertRawTrackRow(
          db.writer,
          path: '/rel-$i.flac',
          audioSha1: 'rel$i'.padRight(40, '0'),
          moodRelaxed: 0.9,
        );
        final values = syntheticEmbedding(i.toDouble());
        await db.writer.execute(
          'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) '
          'VALUES (?, ?)',
          [id, embeddingBlob(values)],
        );
      }
      final repo = TrackRepoImpl(db);
      final mean = await repo.meanEmbeddingForKeywords(['rainy', 'ambient']);
      expect(mean.length, 1280);
      var sumSq = 0.0;
      for (final v in mean) {
        sumSq += v * v;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('empty keywords falls through to global mean over '
        'ready embeddings', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      for (var i = 0; i < 5; i++) {
        final id = await insertRawTrackRow(
          db.writer,
          path: '/gen-$i.flac',
          audioSha1: 'g$i'.padRight(40, '0'),
        );
        await db.writer.execute(
          'INSERT OR REPLACE INTO track_embeddings(track_id, embedding) '
          'VALUES (?, ?)',
          [id, embeddingBlob(syntheticEmbedding(i.toDouble()))],
        );
      }
      final repo = TrackRepoImpl(db);
      final mean = await repo.meanEmbeddingForKeywords(const []);
      expect(mean.length, 1280);
      var sumSq = 0.0;
      for (final v in mean) {
        sumSq += v * v;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('returns zero-vector when library is empty', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final repo = TrackRepoImpl(ctx.db);
      final mean = await repo.meanEmbeddingForKeywords(const []);
      expect(mean.length, 1280);
      for (final v in mean) {
        expect(v, 0.0);
      }
    });
  });
}
