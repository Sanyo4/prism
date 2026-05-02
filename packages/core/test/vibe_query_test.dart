import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('VibeQuery', () {
    test('relaxed + calm only returns rows with mood_relaxed > 0.3 and bpm < 90',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // Calm + relaxed → keep
      await insertRawTrackRow(
        db.writer,
        path: '/c.flac',
        audioSha1: 'c' * 40,
        moodRelaxed: 0.8,
        bpm: 75.0,
      );
      // Mid tempo + relaxed → drop (band fails)
      await insertRawTrackRow(
        db.writer,
        path: '/m.flac',
        audioSha1: 'm' * 40,
        moodRelaxed: 0.9,
        bpm: 100.0,
      );
      // Calm but below the 0.3 mood floor → drop
      await insertRawTrackRow(
        db.writer,
        path: '/x.flac',
        audioSha1: 'x' * 40,
        moodRelaxed: 0.05,
        bpm: 60.0,
      );
      // Calm + on-the-line above floor → keep
      await insertRawTrackRow(
        db.writer,
        path: '/y.flac',
        audioSha1: 'y' * 40,
        moodRelaxed: 0.55,
        bpm: 80.0,
      );

      final results = await db.vibes.run(
        mood: VibeMoodChip.relaxed,
        band: TempoBand.calm,
      );
      expect(results, hasLength(2));
      for (final r in results) {
        expect(r.bpm, isNotNull);
        expect(r.bpm!, lessThan(90.0));
        expect(r.moodScore, greaterThan(0.3),
            reason: '§11.5 — every row must have mood_relaxed > 0.3');
      }
      expect(results.first.moodScore, greaterThan(results.last.moodScore));
    });

    test('hot band filters bpm > 120', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      await insertRawTrackRow(
        db.writer,
        path: '/p1.flac',
        audioSha1: 'p' * 40,
        moodParty: 0.7,
        bpm: 130.0,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/p2.flac',
        audioSha1: 'q' * 40,
        moodParty: 0.7,
        bpm: 110.0,
      );
      final results = await db.vibes.run(
        mood: VibeMoodChip.party,
        band: TempoBand.hot,
      );
      expect(results, hasLength(1));
      expect(results.first.path, '/p1.flac');
    });

    test('null band returns any-bpm rows above the mood floor', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      await insertRawTrackRow(
        db.writer,
        path: '/a.flac',
        audioSha1: 'a' * 40,
        moodHappy: 0.7,
        bpm: 70.0,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/b.flac',
        audioSha1: 'b' * 40,
        moodHappy: 0.6,
        bpm: 140.0,
      );
      // Below floor → excluded.
      await insertRawTrackRow(
        db.writer,
        path: '/c.flac',
        audioSha1: 'c' * 40,
        moodHappy: 0.05,
        bpm: 100.0,
      );
      final results = await db.vibes.run(mood: VibeMoodChip.happy);
      expect(results, hasLength(2));
    });

    test('analysis_pending rows are excluded', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      await insertRawTrackRow(
        db.writer,
        path: '/r.flac',
        audioSha1: 'r' * 40,
        moodSad: 0.6,
        status: 'ready',
        bpm: 80.0,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/p.flac',
        audioSha1: 'p' * 40,
        moodSad: 0.9,
        status: 'analysis_pending',
        bpm: 80.0,
      );
      final results = await db.vibes.run(mood: VibeMoodChip.sad);
      expect(results, hasLength(1));
      expect(results.first.path, '/r.flac');
    });
  });
}
