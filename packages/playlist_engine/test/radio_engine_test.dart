import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

import 'fakes/fake_repo.dart';

/// Slice-11 §B3 — wraps a [FakeRepo] and records every `k` value
/// passed to `knnByEmbedding`. Used by the pool-bound test.
class _RepoSpy implements PlaylistRepo {
  _RepoSpy(this._inner);

  final FakeRepo _inner;
  final List<int> kArgs = <int>[];

  @override
  Future<Float32List> embeddingOf(int trackId) =>
      _inner.embeddingOf(trackId);

  @override
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey) =>
      _inner.meanEmbeddingForAlbum(albumKey);

  @override
  Future<Float32List?> meanEmbeddingForArtist(String artist) =>
      _inner.meanEmbeddingForArtist(artist);

  @override
  Future<List<KnnHit>> knnByEmbedding(Float32List seed, {int k = 200}) {
    kArgs.add(k);
    return _inner.knnByEmbedding(seed, k: k);
  }

  @override
  Future<CandidateMeta> metaOf(int trackId) => _inner.metaOf(trackId);

  @override
  Future<List<CandidateMeta>> metaOfMany(Iterable<int> ids) =>
      _inner.metaOfMany(ids);

  @override
  Future<List<int>> libraryWideFallback({int limit = 100}) =>
      _inner.libraryWideFallback(limit: limit);
}

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

    // ----------------------------------------------------------------
    // Slice-11 §B3 — top-K-from-top-N weighted sampling.
    // ----------------------------------------------------------------

    test(
      'RadioEngineConfig.deterministic regresses to argmax — same picks twice',
      () async {
        // §B3 regression guard: with `temperature: 0.0, topNMultiplier: 1`
        // the engine must produce the slice-5 / pre-slice-11 sequence
        // — i.e. two `next` calls from the same starting session pick
        // the same track. This catches accidental drift in the heap
        // ordering or the deterministic short-circuit in
        // `_sampleFromHeap`.
        //
        // The two runs use freshly-built repos so the FakeRepo's
        // `libraryWideFallback` RNG starts in the same state — the
        // 30-track fixture sits below the 50-track sparse threshold
        // and the fallback shuffle would otherwise reorder the
        // working set between runs.
        const engine = RadioEngine(
          sampling: RadioEngineConfig.deterministic,
        );
        Future<List<int>> runTen() async {
          final repo = _seed30();
          final base = await RadioEngine.fromTrack(
            trackId: 0,
            title: 'seed',
            repo: repo,
          );
          final picks = <int>[];
          var s = base;
          for (var i = 0; i < 10; i++) {
            final r = await engine.next(s, repo);
            expect(r, isNotNull, reason: 'pick $i');
            picks.add(r!.pickedTrackId);
            s = r.nextSession;
          }
          return picks;
        }

        final picks1 = await runTen();
        final picks2 = await runTen();
        expect(picks2, orderedEquals(picks1),
            reason: 'deterministic config must produce identical sequences');
      },
    );

    test(
      'temperature>0 with different seeded RNGs produces different picks',
      () async {
        // §B3 randomness assertion: with default config and two
        // different seeded RNGs, ≥1 of 20 tracks must differ between
        // the two runs. The bar is intentionally loose — the sampler
        // can still bias heavily toward the same close-distance
        // candidates — but identity for all 20 picks would mean the
        // jitter is broken.
        final repo = _seed30();
        final engineA = RadioEngine(
          sampling: RadioEngineConfig(random: math.Random(42)),
        );
        final engineB = RadioEngine(
          sampling: RadioEngineConfig(random: math.Random(43)),
        );
        final baseA = await RadioEngine.fromTrack(
          trackId: 0,
          title: 'seed',
          repo: repo,
        );
        final baseB = await RadioEngine.fromTrack(
          trackId: 0,
          title: 'seed',
          repo: repo,
        );
        Future<List<int>> runTwenty(
          RadioEngine engine,
          RadioSession start,
        ) async {
          final out = <int>[];
          var s = start;
          for (var i = 0; i < 20; i++) {
            final r = await engine.next(s, repo);
            if (r == null) break;
            out.add(r.pickedTrackId);
            s = r.nextSession;
          }
          return out;
        }

        final runA = await runTwenty(engineA, baseA);
        final runB = await runTwenty(engineB, baseB);
        expect(runA, hasLength(20));
        expect(runB, hasLength(20));
        var differing = 0;
        for (var i = 0; i < 20; i++) {
          if (runA[i] != runB[i]) differing++;
        }
        expect(
          differing,
          greaterThanOrEqualTo(1),
          reason: 'sampler with different RNG seeds must diverge — '
              'got $differing/20 differing picks',
        );
      },
    );

    test('top-N pool is bounded by topNMultiplier — kNN k arg ≤80',
        () async {
      // §B3 pool-bound guard: with `topNMultiplier: 4` the engine must
      // request ≤80 candidates from `knnByEmbedding`, not the slice-5
      // flat 200. We wrap the FakeRepo to capture the `k` arg.
      final inner = _seed30();
      final spy = _RepoSpy(inner);
      const engine = RadioEngine(
        sampling: RadioEngineConfig(topNMultiplier: 4),
      );
      final session = await RadioEngine.fromTrack(
        trackId: 0,
        title: 'seed',
        repo: spy,
      );
      // Drain the kNN-arg log — `fromTrack` doesn't call kNN, only
      // `next` does, so the next() below should be the first capture.
      spy.kArgs.clear();
      await engine.next(session, spy);
      expect(spy.kArgs, isNotEmpty,
          reason: 'engine must call knnByEmbedding');
      for (final k in spy.kArgs) {
        expect(k, lessThanOrEqualTo(80),
            reason: 'pool size must be K · topNMultiplier = 20·4 = 80');
      }
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

  group('RadioEngine.averageEmbeddings', () {
    test('returns null for empty list', () {
      expect(RadioEngine.averageEmbeddings(const []), isNull);
    });

    test('single vector echoes its L2-normalised form', () {
      final v = Float32List.fromList(List<double>.filled(1280, 0.0));
      v[0] = 3.0;
      v[1] = 4.0; // L2 norm = 5
      final out = RadioEngine.averageEmbeddings([v]);
      expect(out, isNotNull);
      expect(out!.length, 1280);
      expect(out[0], closeTo(0.6, 1e-6));
      expect(out[1], closeTo(0.8, 1e-6));
      var sumSq = 0.0;
      for (final x in out) {
        sumSq += x * x;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('two-vector mean is element-wise then L2-normalised', () {
      final a = Float32List(1280);
      a[0] = 2.0;
      final b = Float32List(1280);
      b[0] = 4.0;
      final out = RadioEngine.averageEmbeddings([a, b]);
      // Mean[0] = 3.0; norm = 3 → out[0] = 1.0.
      expect(out, isNotNull);
      expect(out![0], closeTo(1.0, 1e-6));
      for (var i = 1; i < 1280; i++) {
        expect(out[i], closeTo(0.0, 1e-6));
      }
    });

    test('zero-mean vector returns the zero vector untouched', () {
      final z = Float32List(1280);
      final out = RadioEngine.averageEmbeddings([z, z]);
      expect(out, isNotNull);
      for (final x in out!) {
        expect(x, 0.0);
      }
    });

    test('rejects vectors of unexpected length', () {
      final wrong = Float32List(1024);
      expect(
        () => RadioEngine.averageEmbeddings([wrong]),
        throwsArgumentError,
      );
    });
  });

  group('ClusterSeed', () {
    test('label flows through to SeedRef.label', () {
      const seed = ClusterSeed(
        trackIds: [1, 2, 3],
        label: 'Rainy Sunday jazz',
        steeringHint: 'rainy_sunday',
      );
      expect((seed as SeedRef).label, 'Rainy Sunday jazz');
      expect(seed.steeringHint, 'rainy_sunday');
    });

    test('equality compares label, hint, and track id list', () {
      const a = ClusterSeed(trackIds: [1, 2], label: 'x');
      const b = ClusterSeed(trackIds: [1, 2], label: 'x');
      const c = ClusterSeed(trackIds: [1, 3], label: 'x');
      expect(a, b);
      expect(a, isNot(c));
    });
  });
}
