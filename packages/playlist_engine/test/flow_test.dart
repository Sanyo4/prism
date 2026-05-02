import 'dart:typed_data';

// Slice 5 §11 / §6: import FlowScorer and Camelot via their *own*
// library URIs, not the barrel — proves the public surface is stable
// for slice 6's PlaylistEngine to reuse without depending on radio
// types.
import 'package:prism_playlist_engine/camelot.dart';
import 'package:prism_playlist_engine/flow.dart';
import 'package:prism_playlist_engine/playlist_engine.dart' as engine;
import 'package:prism_playlist_engine/repo.dart';
import 'package:test/test.dart';

CandidateMeta _meta({
  int id = 1,
  String artist = 'a',
  double bpm = 110.0,
  String key = '',
}) {
  return CandidateMeta(
    trackId: id,
    artistKey: artist,
    title: 't$id',
    key: key,
    year: null,
    bpm: bpm,
    moodHappy: 0,
    moodSad: 0,
    moodRelaxed: 0,
    moodAggressive: 0,
    moodParty: 0,
    danceability: 0,
    voiceInstrumental: 0,
  );
}

engine.RadioSession _session({
  Map<engine.SteerChip, engine.ChipState> chips = const {},
  List<int> history = const [],
  Map<int, int> skips = const {},
}) {
  return engine.RadioSession(
    seed: const engine.TrackSeed(trackId: 0, title: 'seed'),
    seedEmbedding: Float32List(1280),
    chips: chips,
    history: history,
    skipWeights: skips,
  );
}

void main() {
  const flow = FlowScorer();

  group('hard rejects', () {
    test('history window — recent id is rejected', () {
      final cand = _meta(id: 42, artist: 'a');
      final prev = _meta(id: 41, artist: 'b');
      final session = _session(history: [40, 41, 42]);
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, isNull);
    });

    test('history window respects max cap', () {
      // 30 prior picks; cand at index 0 is way outside the default 20.
      final history = List.generate(30, (i) => i + 100);
      final cand = _meta(id: 100); // oldest in history
      final prev = _meta(id: 129);
      final session = _session(history: history);
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      // Should pass — outside the 20-pick window.
      expect(result, isNotNull);
    });

    test('skip-spam scales the history window', () {
      // candidate skipped 4 times → window stretches to 80
      final history = List.generate(40, (i) => i + 100);
      final cand = _meta(id: 100);
      final prev = _meta(id: 139);
      final session = _session(
        history: history,
        skips: const {100: 4},
      );
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, isNull);
    });

    test('same-artist window — three prior picks all same artist', () {
      final cand = _meta(id: 5, artist: 'cure');
      final prev = _meta(id: 4, artist: 'cure');
      final history = [1, 2, 3];
      final historyMeta = {
        1: _meta(id: 1, artist: 'cure'),
        2: _meta(id: 2, artist: 'cure'),
        3: _meta(id: 3, artist: 'cure'),
      };
      final session = _session(history: history);
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: historyMeta,
      );
      expect(result, isNull);
    });

    test('moreLikeThisArtist disables same-artist reject', () {
      final cand = _meta(id: 5, artist: 'cure');
      final prev = _meta(id: 4, artist: 'cure');
      final history = [1, 2, 3];
      final historyMeta = {
        1: _meta(id: 1, artist: 'cure'),
        2: _meta(id: 2, artist: 'cure'),
        3: _meta(id: 3, artist: 'cure'),
      };
      final session = _session(
        history: history,
        chips: const {
          engine.SteerChip.moreLikeThisArtist: engine.ChipState(10),
        },
      );
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: historyMeta,
      );
      expect(result, isNotNull);
    });

    test('BPM window — |Δ| > 15 rejects (default)', () {
      final cand = _meta(id: 1, bpm: 90.0);
      final prev = _meta(id: 0, bpm: 130.0);
      final session = _session();
      expect(
        flow.scoreOrReject(
          candidate: cand,
          previous: prev,
          session: session,
          historyMeta: const {},
        ),
        isNull,
      );
    });

    test('moreIntense widens BPM window to 25', () {
      final cand = _meta(id: 1, bpm: 100.0);
      final prev = _meta(id: 0, bpm: 122.0);
      final session = _session(
        chips: const {engine.SteerChip.moreIntense: engine.ChipState(10)},
      );
      // |Δ| = 22, default rejects, intense passes.
      expect(
        flow.scoreOrReject(
          candidate: cand,
          previous: prev,
          session: session,
          historyMeta: const {},
        ),
        isNotNull,
      );
    });

    test('half-time / double-time leniency', () {
      // 60 BPM ↔ 120 BPM should pass (double-time).
      final cand = _meta(id: 1, bpm: 60.0);
      final prev = _meta(id: 0, bpm: 120.0);
      final session = _session();
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, isNotNull);
    });
  });

  group('Camelot bonus path', () {
    test('matching wheel positions earn a bonus (>1)', () {
      final cand = _meta(id: 2, key: 'Fm', bpm: 110); // 4A
      final prev = _meta(id: 1, key: 'Cm', bpm: 110); // 5A
      final session = _session();
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, isNotNull);
      expect(result!, greaterThan(1.0));
    });

    test('cross-wheel keys earn a penalty (<1)', () {
      // 4A ↔ 10A → distance 6
      final cand = _meta(id: 2, key: 'Fm', bpm: 110);
      final prev = _meta(id: 1, key: 'Bm', bpm: 110);
      final session = _session();
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, isNotNull);
      expect(result!, lessThan(1.0));
    });

    test('unparseable key falls through to 1.0', () {
      final cand = _meta(id: 2, key: 'wat', bpm: 110);
      final prev = _meta(id: 1, key: 'Cm', bpm: 110);
      final session = _session();
      final result = flow.scoreOrReject(
        candidate: cand,
        previous: prev,
        session: session,
        historyMeta: const {},
      );
      expect(result, 1.0);
    });
  });

  test('slice-6 reuse smoke test — Camelot + FlowScorer importable', () {
    // Using the directly-imported symbols (not via the barrel) is
    // the actual contract; this test exists so the imports above
    // are exercised at runtime.
    expect(Camelot.parse('Fm'), const CamelotKey(4, minor: true));
    expect(const FlowScorer().sameArtistWindow, 3);
  });
}
