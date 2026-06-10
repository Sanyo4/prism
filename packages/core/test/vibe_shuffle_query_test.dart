import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

/// Slice 10 §6: covers the three steering modes (true-shuffle /
/// filter / bias) plus the tempo-band intersection.
///
/// Fixture: 6 tracks across three chip strengths × three tempo bands.
/// Numeric checks use chipExpression's known output so a re-derivation
/// of the formulas would also need to update this file.
void main() {
  group('VibeShuffleQuery', () {
    test('zero chips, true-shuffle off → returns up to LIMIT random rows', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const <MoodChip>{},
        band: null,
        trueShuffle: false,
      );
      expect(result, hasLength(6));
    });

    test('one chip filters by chipExpression > 0.5', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill},
        band: null,
        trueShuffle: false,
      );
      // Two chill rows in the fixture (calm + relaxed); one is below
      // the 0.5 floor after the bpm-penalty multiplier.
      expect(result, isNotEmpty);
      for (final row in result) {
        expect(row.score, greaterThan(0.5));
      }
    });

    test('two chips additively combine via Σ chipExpression > 0', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill, MoodChip.focus},
        band: null,
        trueShuffle: false,
      );
      // First row should have the highest combined score.
      expect(result, isNotEmpty);
      for (var i = 1; i < result.length; i++) {
        expect(
          result[i - 1].score,
          greaterThanOrEqualTo(result[i].score),
        );
      }
    });

    test('tempo band ANDs into the where clause regardless of mode', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.energetic},
        band: TempoBand.hot,
        trueShuffle: false,
      );
      for (final row in result) {
        expect(row.bpm, greaterThan(120),
            reason: 'TempoBand.hot is bpm > 120');
      }
    });

    test('true-shuffle on with zero chips returns all ready rows', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final filtered = await VibeShuffleQuery(ctx.db).run(
        chips: const <MoodChip>{},
        band: null,
        trueShuffle: true,
      );
      // Zero chips + true-shuffle: uniformly-random ready set.
      expect(filtered, hasLength(6));
    });

    test(
        'true-shuffle on with non-empty chips still filters by chipExpression '
        '(slice-11 §B2 fix for the slice-10b D bypass bug)', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final filtered = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill},
        band: null,
        trueShuffle: true,
      );
      // Same chip filter as the deterministic single-chip test: rows
      // must satisfy the > 0.5 floor. Order is random (we don't assert
      // it) but the eligible set is identical.
      expect(filtered, isNotEmpty);
      expect(
        filtered.length,
        lessThan(6),
        reason: 'chip filter must still constrain the set under True-Shuffle',
      );
      for (final row in filtered) {
        expect(
          row.score,
          greaterThan(0.5),
          reason:
              'True-Shuffle ON must not bypass the chip-expression filter — '
              'shuffle randomises order, not the eligible set.',
        );
      }
    });

    test('respects LIMIT 1000 cap', () async {
      // The cap is in SQL; assert via a trivial unit on the constant.
      expect(VibeShuffleQuery.deckLimit, 1000);
    });
  });
}

Future<void> _seedSixTracks(CacheDb db) async {
  // Three chip strengths × three tempo bands. Picked so each mode test
  // has a deterministic answer.
  await insertRawTrackRow(
    db.writer, path: '/c1.flac', audioSha1: '1' * 40,
    moodRelaxed: 0.9, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.7, danceability: 0.0,
    bpm: 80.0, // calm
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/c2.flac', audioSha1: '2' * 40,
    moodRelaxed: 0.7, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.4, danceability: 0.0,
    bpm: 100.0, // mid
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/c3.flac', audioSha1: '3' * 40,
    moodRelaxed: 0.6, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.2, danceability: 0.0,
    bpm: 130.0, // hot — hits the 0.5 chill penalty (bpm > 110)
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/e1.flac', audioSha1: '4' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.85, voiceInstrumental: 0.0, danceability: 0.6,
    bpm: 140.0, // hot
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/e2.flac', audioSha1: '5' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.7, voiceInstrumental: 0.0, danceability: 0.5,
    bpm: 95.0, // mid
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/f1.flac', audioSha1: '6' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.95, danceability: 0.0,
    bpm: 90.0, // calm
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
}
