/// Slice-6 reuse contract: `PlaylistEngine` must reuse slice-5's
/// `FlowScorer` + `Camelot` *verbatim* — no subclassing, no
/// duplicated rule implementation. This test imports them via the
/// same paths slice 5 uses (verbatim from `flow_test.dart`),
/// instantiates a `PlaylistEngine`, and proves a `generate` call
/// invokes `FlowScorer.scoreOrReject` at least once and produces
/// an ordered playlist with no same-artist or BPM-window
/// violations.
library;

// Import via the same library URIs slice 5 uses — proves both
// barrel and direct paths surface the same classes. Lints
// (`unnecessary_import`) are suppressed below to keep the locked
// contract paths visible at the top of the file.
// ignore: unnecessary_import
import 'package:prism_playlist_engine/camelot.dart';
// ignore: unnecessary_import
import 'package:prism_playlist_engine/flow.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

import 'fakes/fake_llm_backend.dart';
import 'fakes/fake_track_repo.dart';

/// FlowScorer subclass that delegates verbatim to slice-5's
/// implementation but bumps a heap-allocated counter on each call.
/// Slice-5's `FlowScorer` is `@immutable`, so the counter lives in
/// a holder we capture by reference rather than as an instance
/// field. Proves the engine *invokes* the slice-5 method without
/// re-implementing it.
class _CallCounter {
  int n = 0;
}

class _CountingFlow extends FlowScorer {
  final _CallCounter counter;
  const _CountingFlow(this.counter);

  @override
  double? scoreOrReject({
    required candidate,
    required previous,
    required session,
    required historyMeta,
  }) {
    counter.n += 1;
    return super.scoreOrReject(
      candidate: candidate,
      previous: previous,
      session: session,
      historyMeta: historyMeta,
    );
  }
}

void main() {
  test('Camelot.parse importable from camelot.dart', () {
    expect(Camelot.parse('Fm'), const CamelotKey(4, minor: true));
  });

  test('FlowScorer importable from flow.dart with stable defaults', () {
    const f = FlowScorer();
    expect(f.sameArtistWindow, 3);
    expect(f.bpmWindow, 15.0);
  });

  test('PlaylistEngine.generate invokes FlowScorer.scoreOrReject', () async {
    final repo = _seedRepo();
    final llm = FakeLlmBackend(intentScript: <Object>[
      Intent.fromJson(<String, dynamic>{
        'mood_targets': [
          {'mood': 'sad', 'min': 0.3}
        ],
        'energy_arc': 'flat',
        'duration_minutes': 45,
        'narrative': 'evening drive'
      }),
    ]);
    final counter = _CallCounter();
    final flow = _CountingFlow(counter);
    final engine = PlaylistEngine(flow: flow);
    final result = await engine.generate(
      vibe: 'evening drive',
      llm: llm,
      repo: repo,
      length: 12,
    );
    expect(counter.n, greaterThan(0));
    expect(result.trackIds.length, 12);
    expect(result.debug.flowedSize, greaterThan(0));
    await llm.dispose();
  });

  test('no same-artist back-to-back, |Δbpm| ≤ 15 across all pairs', () async {
    final repo = _seedRepo();
    final llm = FakeLlmBackend(intentScript: <Object>[
      Intent.fromJson(<String, dynamic>{
        'mood_targets': [
          {'mood': 'relaxed', 'min': 0.3}
        ],
        'energy_arc': 'flat',
        'duration_minutes': 45,
        'narrative': 'flow check'
      }),
    ]);
    final engine = const PlaylistEngine();
    final result = await engine.generate(
      vibe: 'flow check',
      llm: llm,
      repo: repo,
      length: 12,
    );
    final cands = result.candidates;
    for (var i = 1; i < cands.length; i++) {
      expect(
        cands[i].artistKey == cands[i - 1].artistKey,
        isFalse,
        reason: 'same-artist adjacency at $i: ${cands[i].artistKey}',
      );
      // BPM window: |Δ| ≤ 15 OR half/double-time leniency.
      final a = cands[i - 1].bpm;
      final b = cands[i].bpm;
      final delta = (a - b).abs();
      final halfDouble =
          (b - 2 * a).abs() < 15.0 || (b - a / 2).abs() < 15.0;
      expect(
        delta <= 15.0 || halfDouble,
        isTrue,
        reason: 'BPM jump $a → $b at $i exceeds window',
      );
    }
    await llm.dispose();
  });
}

FakeTrackRepo _seedRepo() {
  final repo = FakeTrackRepo();
  // 30 candidates with rotating artists + smoothly varying BPM so
  // the flow scorer always has something to pick.
  final artists = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'];
  for (var i = 0; i < 30; i++) {
    repo.addTrack(
      id: i + 1,
      artist: artists[i % artists.length],
      title: 't$i',
      bpm: 95 + (i % 6).toDouble(),
      moodSad: 0.6,
      moodRelaxed: 0.6,
      year: 1990 + (i % 25),
    );
  }
  return repo;
}
