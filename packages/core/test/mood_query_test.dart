import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('MoodQuery', () {
    test('Sad chip top result has the highest mood_sad', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      // Seed: three tracks with different mood profiles.
      final happyId = await insertRawTrackRow(
        db.writer,
        path: '/h.flac',
        audioSha1: 'h' * 40,
        moodHappy: 0.9,
        moodSad: 0.1,
        moodAggressive: 0.0,
        moodRelaxed: 0.5,
        moodParty: 0.2,
        bpm: 120.0,
        danceability: 0.7,
        voiceInstrumental: 0.1,
      );
      final sadId = await insertRawTrackRow(
        db.writer,
        path: '/s.flac',
        audioSha1: 's' * 40,
        moodHappy: 0.1,
        moodSad: 0.85,
        moodAggressive: 0.0,
        moodRelaxed: 0.6,
        moodParty: 0.0,
        bpm: 80.0,
        danceability: 0.2,
        voiceInstrumental: 0.5,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/m.flac',
        audioSha1: 'm' * 40,
        moodHappy: 0.4,
        moodSad: 0.4,
        moodAggressive: 0.1,
        moodRelaxed: 0.4,
        moodParty: 0.1,
        bpm: 100.0,
        danceability: 0.5,
        voiceInstrumental: 0.3,
      );
      expect(happyId, isPositive);

      final results = await db.moods.run(MoodChip.sad, limit: 10);
      expect(results, isNotEmpty);
      expect(results.first.trackId, sadId,
          reason: 'top result for Sad should be the row with highest mood_sad');
      expect(results.first.moodConfidence, closeTo(0.85, 1e-9));
    });

    test('Chill chip applies bpm penalty for tracks above 110 BPM', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final calmRelaxedId = await insertRawTrackRow(
        db.writer,
        path: '/c.flac',
        audioSha1: 'c' * 40,
        moodRelaxed: 0.7,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodAggressive: 0.0,
        moodParty: 0.0,
        bpm: 80.0,
      );
      // Same relaxed score but at high BPM — should be penalised x0.5.
      await insertRawTrackRow(
        db.writer,
        path: '/f.flac',
        audioSha1: 'f' * 40,
        moodRelaxed: 0.7,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodAggressive: 0.0,
        moodParty: 0.0,
        bpm: 140.0,
      );
      final results = await db.moods.run(MoodChip.chill, limit: 10);
      expect(results, hasLength(2));
      expect(results.first.trackId, calmRelaxedId);
      expect(results.first.moodConfidence, closeTo(0.7, 1e-9));
      expect(results.last.moodConfidence, closeTo(0.35, 1e-9));
    });

    test('Energetic chip prefers high mood_party / danceability with high BPM',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final hotPartyId = await insertRawTrackRow(
        db.writer,
        path: '/p.flac',
        audioSha1: 'p' * 40,
        moodParty: 0.8,
        danceability: 0.5,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodAggressive: 0.0,
        moodRelaxed: 0.0,
        bpm: 130.0,
      );
      // High party but slow — should rank below.
      await insertRawTrackRow(
        db.writer,
        path: '/q.flac',
        audioSha1: 'q' * 40,
        moodParty: 0.8,
        danceability: 0.5,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodAggressive: 0.0,
        moodRelaxed: 0.0,
        bpm: 95.0,
      );
      final results = await db.moods.run(MoodChip.energetic, limit: 10);
      expect(results.first.trackId, hotPartyId);
    });

    test('Focus penalises aggressive + party while rewarding instrumental',
        () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      final instrumentalId = await insertRawTrackRow(
        db.writer,
        path: '/i.flac',
        audioSha1: 'i' * 40,
        voiceInstrumental: 0.9,
        moodAggressive: 0.0,
        moodParty: 0.0,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodRelaxed: 0.0,
        bpm: 100.0,
      );
      // High instrumental but also aggressive → should rank lower.
      await insertRawTrackRow(
        db.writer,
        path: '/a.flac',
        audioSha1: 'a' * 40,
        voiceInstrumental: 0.9,
        moodAggressive: 0.7,
        moodParty: 0.0,
        moodHappy: 0.0,
        moodSad: 0.0,
        moodRelaxed: 0.0,
        bpm: 100.0,
      );
      final results = await db.moods.run(MoodChip.focus, limit: 10);
      expect(results.first.trackId, instrumentalId);
      // First is voice_instrumental * 1 * 1 = 0.9; second is 0.9 * 0.3 * 1 = 0.27.
      expect(results.first.moodConfidence, closeTo(0.9, 1e-9));
      expect(results.last.moodConfidence, closeTo(0.27, 1e-9));
    });

    test('only ready rows surface', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final db = ctx.db;
      await insertRawTrackRow(
        db.writer,
        path: '/r.flac',
        audioSha1: 'r' * 40,
        moodHappy: 0.9,
        status: 'ready',
        // need other fields to qualify for filters
        moodSad: 0.0,
        moodAggressive: 0.0,
        moodRelaxed: 0.0,
        moodParty: 0.0,
        bpm: 100.0,
      );
      await insertRawTrackRow(
        db.writer,
        path: '/p.flac',
        audioSha1: 'p' * 40,
        moodHappy: 0.95,
        status: 'analysis_pending',
        bpm: 100.0,
      );
      final results = await db.moods.run(MoodChip.happy);
      expect(results, hasLength(1));
      expect(results.first.path, '/r.flac');
    });

    group('MoodQuery.chipExpression', () {
      test('happy returns mood_happy', () {
        expect(MoodQuery.chipExpression(MoodChip.happy), 'mood_happy');
      });

      test('sad returns mood_sad', () {
        expect(MoodQuery.chipExpression(MoodChip.sad), 'mood_sad');
      });

      test('chill applies bpm < 110 weighting', () {
        expect(
          MoodQuery.chipExpression(MoodChip.chill),
          'mood_relaxed * CASE WHEN bpm < 110 THEN 1.0 ELSE 0.5 END',
        );
      });

      test('energetic uses MAX(party, danceability) and bpm > 110 weighting',
          () {
        expect(
          MoodQuery.chipExpression(MoodChip.energetic),
          'MAX(COALESCE(mood_party, 0.0), COALESCE(danceability, 0.0)) '
          ' * CASE WHEN bpm > 110 THEN 1.0 ELSE 0.5 END',
        );
      });

      test('focus penalises aggressive + party', () {
        expect(
          MoodQuery.chipExpression(MoodChip.focus),
          'voice_instrumental '
          ' * (1.0 - COALESCE(mood_aggressive, 0.0)) '
          ' * (1.0 - COALESCE(mood_party, 0.0))',
        );
      });
    });

    group('recencyFactor', () {
      test('returns 1.0 for now (zero days elapsed)', () {
        final now = DateTime.now().millisecondsSinceEpoch;
        expect(
          recencyFactor(addedAtMs: now, nowMs: now),
          closeTo(1.0, 1e-9),
        );
      });

      test('decays exponentially with age', () {
        final now = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
        final yearAgo = now - 365 * Duration.millisecondsPerDay;
        // 0.5 + 0.5 * exp(-1) ≈ 0.6839
        expect(
          recencyFactor(addedAtMs: yearAgo, nowMs: now),
          closeTo(0.5 + 0.5 * 0.36787944117, 1e-6),
        );
      });

      test('floor of 0.5 as days → ∞', () {
        final now = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
        final ancient = now - 100 * 365 * Duration.millisecondsPerDay;
        expect(
          recencyFactor(addedAtMs: ancient, nowMs: now),
          closeTo(0.5, 1e-3),
        );
      });
    });
  });
}
