import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

import 'fakes/fake_repo.dart';

/// Helper that seeds a 30-track FakeRepo with a spread of artists,
/// BPMs, and keys. Track 0 is the seed; remaining tracks span 5
/// artists and BPMs in [90, 140].
FakeRepo _seed30() {
  final repo = FakeRepo();
  // Seed track at id=0 — set its embedding to all-zeroes so distances
  // to every other (non-zero) embedding are non-trivial.
  repo.embeddings[0] = Float32List(1280);
  repo.metas[0] = const CandidateMeta(
    trackId: 0,
    artistKey: 'seed',
    title: 'Seed',
    key: 'Cm',
    year: 2010,
    bpm: 110.0,
    moodHappy: 0.5,
    moodSad: 0.5,
    moodRelaxed: 0.5,
    moodAggressive: 0.5,
    moodParty: 0.5,
    danceability: 0.5,
    voiceInstrumental: 0.5,
  );
  repo.artistTracks.putIfAbsent('seed', () => []).add(0);
  for (var i = 1; i <= 30; i++) {
    final artist = 'artist${(i % 5) + 1}';
    final bpm = 90 + ((i * 7) % 51).toDouble(); // 90..140
    final keys = ['Cm', 'Fm', 'Gm', 'Am', 'Em', 'Dm'];
    repo.addTrack(
      id: i,
      artist: artist,
      title: 't$i',
      bpm: bpm,
      year: 2000 + (i % 25),
      key: keys[i % keys.length],
      moodHappy: ((i * 0.07) % 1.0),
      moodSad: ((i * 0.13) % 1.0),
      moodRelaxed: ((i * 0.11) % 1.0),
      moodAggressive: ((i * 0.17) % 1.0),
      moodParty: ((i * 0.19) % 1.0),
      album: 'album${i % 3}',
    );
  }
  return repo;
}

void main() {
  group('RadioEngine.from*', () {
    test('fromTrack builds an L2-normalized seed embedding', () async {
      final repo = _seed30();
      final session = await RadioEngine.fromTrack(
        trackId: 1,
        title: 't1',
        repo: repo,
      );
      var sumSq = 0.0;
      for (final v in session.seedEmbedding) {
        sumSq += v * v;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('fromAlbum returns null when no rows match', () async {
      final repo = FakeRepo();
      expect(
        () => RadioEngine.fromAlbum(
          albumKey: 'nope',
          title: 'no album',
          repo: repo,
        ),
        throwsStateError,
      );
    });

    test('fromArtist builds when at least one ready row', () async {
      final repo = _seed30();
      final session = await RadioEngine.fromArtist(
        artist: 'artist1',
        label: 'Artist 1',
        repo: repo,
      );
      expect(session.seedEmbedding.length, 1280);
    });
  });

  group('RadioEngine.next', () {
    test('20 picks against 30 fakes — zero hard-rule violations',
        () async {
      // §11 verification item 2.
      final repo = _seed30();
      const engine = RadioEngine();
      var session = await RadioEngine.fromTrack(
        trackId: 0,
        title: 'Seed',
        repo: repo,
      );
      // Force a stable history-based selection: each iteration picks
      // one and asserts the picked track doesn't violate any flow rule
      // versus the previous pick.
      final picked = <int>[];
      for (var i = 0; i < 20; i++) {
        final pick = await engine.next(session, repo);
        expect(pick, isNotNull, reason: 'step $i');
        final result = pick!;
        picked.add(result.pickedTrackId);
        // No id repeats inside the 20-pick history window.
        final tail = picked.length > 20 ? picked.skip(picked.length - 20)
            : picked;
        expect(
          tail.toList()..sort(),
          orderedEquals(tail.toSet().toList()..sort()),
          reason: 'duplicate within history window at step $i',
        );
        session = result.nextSession;
      }
      // History tracks every pick.
      expect(session.history, hasLength(20));
      // No same-artist 4-streak (the engine's same-artist rule kicks
      // when the previous 3 share artist; the 4th must differ).
      for (var i = 3; i < session.history.length; i++) {
        final ids = session.history.sublist(i - 3, i + 1);
        final artists = ids
            .map((id) => repo.metas[id]?.artistKey ?? '')
            .toSet();
        expect(artists.length, greaterThan(1),
            reason: 'four-in-a-row same artist at $i');
      }
    });

    test('sparse-neighborhood fallback engages with <50 candidates',
        () async {
      // §10 risk 1 — 5 tracks total, kNN comes back with <50, fallback
      // engages and the engine still returns a pick.
      final repo = FakeRepo();
      // Seed at id=0
      repo.embeddings[0] = Float32List(1280);
      repo.metas[0] = const CandidateMeta(
        trackId: 0,
        artistKey: 'seed',
        title: 'seed',
        key: '',
        year: null,
        bpm: 100,
        moodHappy: 0,
        moodSad: 0,
        moodRelaxed: 0,
        moodAggressive: 0,
        moodParty: 0,
        danceability: 0,
        voiceInstrumental: 0,
      );
      for (var i = 1; i <= 4; i++) {
        repo.addTrack(id: i, artist: 'a$i', title: 't$i', bpm: 100);
      }
      final session = await RadioEngine.fromTrack(
        trackId: 0,
        title: 'seed',
        repo: repo,
      );
      const engine = RadioEngine();
      final pick = await engine.next(session, repo);
      expect(pick, isNotNull);
      expect(pick!.debug.fromKnn, isFalse,
          reason: 'sparse fallback should mark fromKnn=false');
    });

    test('skip-spam suppression — 5 skipped tracks stay out of next 40',
        () async {
      // §11 item 9 / §10 risk 5. Skipping a track in production puts
      // it in history *and* bumps its skipWeight; the FlowScorer
      // extends the per-track rejection window to `20 · skipWeight`,
      // capped at 80. Here we simulate exactly that pre-state.
      // Use a 100-track library so the per-pick BPM window doesn't
      // starve over a 40-pick run.
      final repo = FakeRepo();
      repo.embeddings[0] = Float32List(1280);
      repo.metas[0] = const CandidateMeta(
        trackId: 0,
        artistKey: 'seed',
        title: 'Seed',
        key: 'Cm',
        year: 2010,
        bpm: 110.0,
        moodHappy: 0.5,
        moodSad: 0.5,
        moodRelaxed: 0.5,
        moodAggressive: 0.5,
        moodParty: 0.5,
        danceability: 0.5,
        voiceInstrumental: 0.5,
      );
      repo.artistTracks.putIfAbsent('seed', () => []).add(0);
      // 100 candidate tracks, 10 artists, BPM tight cluster around 110
      // so the BPM window doesn't starve the 40-pick run.
      for (var i = 1; i <= 100; i++) {
        final artist = 'artist${(i % 10) + 1}';
        final keys = ['Cm', 'Fm', 'Gm', 'Am', 'Em', 'Dm'];
        repo.addTrack(
          id: i,
          artist: artist,
          title: 't$i',
          bpm: 105 + ((i * 3) % 11).toDouble(), // 105..115
          year: 2000 + (i % 25),
          key: keys[i % keys.length],
          moodHappy: ((i * 0.07) % 1.0),
          moodSad: ((i * 0.13) % 1.0),
          moodRelaxed: ((i * 0.11) % 1.0),
          moodAggressive: ((i * 0.17) % 1.0),
          moodParty: ((i * 0.19) % 1.0),
        );
      }
      var session = await RadioEngine.fromTrack(
        trackId: 0,
        title: 'seed',
        repo: repo,
      );
      // The five skipped tracks are at the head of history (oldest
      // first). They each have skipWeight ≥ 4 → effective window 80.
      final history = <int>[1, 2, 3, 4, 5];
      // Pad recent history with 35 unrelated ids so the skipped tracks
      // sit ~40 picks in the past — i.e. they would be evicted from
      // the default 20-window without skip scaling.
      for (var i = 0; i < 35; i++) {
        history.add(1000 + i);
      }
      session = RadioSession(
        seed: session.seed,
        seedEmbedding: session.seedEmbedding,
        chips: session.chips,
        history: history,
        skipWeights: const {1: 4, 2: 4, 3: 4, 4: 4, 5: 4},
        lookahead: session.lookahead,
        lastPickArtistKey: session.lastPickArtistKey,
      );

      const engine = RadioEngine();
      final blocked = {1, 2, 3, 4, 5};
      for (var i = 0; i < 40; i++) {
        final pick = await engine.next(session, repo);
        expect(pick, isNotNull);
        expect(blocked.contains(pick!.pickedTrackId), isFalse,
            reason: 'skip-spam id surfaced at step $i: ${pick.pickedTrackId}');
        session = pick.nextSession;
      }
    });

    test('conflicting chips fire the assertion', () async {
      final repo = _seed30();
      const engine = RadioEngine();
      var session = await RadioEngine.fromTrack(
        trackId: 0,
        title: 'seed',
        repo: repo,
      );
      // Bypass the UI's mutual-exclusion path to force the bad state.
      session = RadioSession(
        seed: session.seed,
        seedEmbedding: session.seedEmbedding,
        chips: const {
          SteerChip.calmer: ChipState(10),
          SteerChip.moreIntense: ChipState(10),
        },
        history: session.history,
        skipWeights: session.skipWeights,
        lookahead: session.lookahead,
      );
      // assert() only fires in debug Dart (`--enable-asserts`).
      // `dart test` enables asserts by default.
      expect(() async => engine.next(session, repo),
          throwsA(isA<AssertionError>()));
    });
  });

  group('RadioSession invariants', () {
    test('withChipToggled clears the opposing chip', () {
      var session = RadioSession(
        seed: const TrackSeed(trackId: 0, title: 's'),
        seedEmbedding: Float32List(1280),
        chips: const {SteerChip.slower: ChipState(10)},
      );
      session = session.withChipToggled(SteerChip.faster);
      expect(session.chips.containsKey(SteerChip.slower), isFalse);
      expect(session.chips[SteerChip.faster]?.ticksRemaining, 10);
    });

    test('copyAfterPick decays every active chip exactly one tick', () {
      final session = RadioSession(
        seed: const TrackSeed(trackId: 0, title: 's'),
        seedEmbedding: Float32List(1280),
        chips: const {
          SteerChip.faster: ChipState(10),
          SteerChip.happier: ChipState(3),
        },
      );
      final next = session.copyAfterPick(7, 'a');
      expect(next.chips[SteerChip.faster]?.ticksRemaining, 9);
      expect(next.chips[SteerChip.happier]?.ticksRemaining, 2);
      expect(next.history, [7]);
      expect(next.lastPickArtistKey, 'a');
    });

    test('decayed chips drop out of the active map', () {
      final session = RadioSession(
        seed: const TrackSeed(trackId: 0, title: 's'),
        seedEmbedding: Float32List(1280),
        chips: const {SteerChip.faster: ChipState(1)},
      );
      final next = session.copyAfterPick(7, 'a');
      expect(next.chips.containsKey(SteerChip.faster), isFalse);
    });
  });
}
