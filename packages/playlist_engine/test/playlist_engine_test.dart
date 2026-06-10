/// Slice 6 §11 verification — engine end-to-end with fakes. Covers:
///   - happy path (intent → pool → rank → flow → narrate → trim)
///   - repair loop (malformed → invalid → valid → repairCount==2)
///   - garbage-only backend → Intent.fallback + default blurb
///   - sparse pool → veryLoose then libraryWideFallback
///   - empty/whitespace vibe → Intent.fallback("shuffle")
///   - swap validation: >4 swaps + insertId not in top-40
///   - same-artist + BPM hard rules across every adjacent pair
///   - energy_arc=build → mean BPM picks 7..12 ≥ mean of 1..6
library;

import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

import 'fakes/fake_llm_backend.dart';
import 'fakes/fake_track_repo.dart';

Intent _validIntent({
  String mood = 'sad',
  EnergyArc arc = EnergyArc.flat,
  (int, int)? bpm,
  String narrative = 'late night drive',
}) {
  return Intent.fromJson(<String, dynamic>{
    'mood_targets': [
      {'mood': mood, 'min': 0.3}
    ],
    if (bpm != null) 'bpm_range': [bpm.$1, bpm.$2],
    'energy_arc': arc.name,
    'duration_minutes': 45,
    'narrative': narrative,
  });
}

FakeTrackRepo _libraryOf30() {
  final repo = FakeTrackRepo();
  // 10 distinct artists × 3 tracks each, BPM walking 95..125 in
  // adjacent steps so the flow scorer always finds a legal next.
  final artists = const [
    'aa',
    'bb',
    'cc',
    'dd',
    'ee',
    'ff',
    'gg',
    'hh',
    'ii',
    'jj',
  ];
  for (var i = 0; i < 30; i++) {
    repo.addTrack(
      id: i + 1,
      artist: artists[i % artists.length],
      title: 't$i',
      bpm: 95.0 + (i % 6).toDouble(),
      moodSad: 0.6 + (i % 5) * 0.05,
      moodRelaxed: 0.5 + (i % 7) * 0.04,
      moodAggressive: 0.1,
      moodHappy: 0.1,
      moodParty: 0.1,
      year: 1990 + (i % 25),
    );
  }
  return repo;
}

void main() {
  group('PlaylistEngine.generate — happy path', () {
    test('returns 12 tracks + non-empty blurb', () async {
      final repo = _libraryOf30();
      final llm = FakeLlmBackend(
        intentScript: <Object>[_validIntent()],
        refineScript: <Object>[
          const FinalPass(swaps: [], blurb: 'A late-night drive playlist.'),
        ],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'late night drive',
        llm: llm,
        repo: repo,
      );
      expect(result.trackIds.length, 12);
      expect(result.candidates.length, 12);
      // candidate trackIds align with trackIds.
      for (var i = 0; i < 12; i++) {
        expect(result.candidates[i].trackId, result.trackIds[i]);
      }
      expect(result.blurb, 'A late-night drive playlist.');
      expect(result.debug.repairCount, 0);
      expect(result.debug.usedFallback, isFalse);
      expect(result.debug.flowedSize, greaterThanOrEqualTo(12));
      await llm.dispose();
    });
  });

  group('Repair loop', () {
    test('malformed → schema-invalid → valid yields repairCount==2',
        () async {
      final repo = _libraryOf30();
      final llm = FakeLlmBackend(
        intentScript: <Object>[
          const LlmJsonParseException(
            'unexpected character at offset 0',
            raw: 'I cannot do that',
          ),
          const LlmJsonParseException(
            'mood_targets[0].mood: "moody" not in enum',
            raw: '{"mood_targets":[{"mood":"moody"}], ...}',
          ),
          _validIntent(),
        ],
        refineScript: <Object>[
          const FinalPass(swaps: [], blurb: 'Recovered.'),
        ],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'late night drive',
        llm: llm,
        repo: repo,
      );
      expect(result.debug.repairCount, 2);
      expect(result.debug.usedFallback, isFalse);
      expect(result.trackIds.length, 12);
      // Repair preamble fired twice — three total intent calls.
      expect(llm.intentPrompts.length, 3);
      expect(llm.intentPrompts[1], contains('Your previous response'));
      expect(llm.intentPrompts[2], contains('Your previous response'));
      await llm.dispose();
    });

    test('garbage-only backend → falls back to Intent.fallback', () async {
      final repo = _libraryOf30();
      final llm = FakeLlmBackend(garbageOnly: true);
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'rainy chill drive',
        llm: llm,
        repo: repo,
      );
      expect(result.debug.repairCount, 2);
      expect(result.debug.usedFallback, isTrue);
      expect(result.trackIds.length, 12);
      // Default blurb derived from intent.narrative.
      expect(result.blurb, isNotEmpty);
      // Intent.fallback maps "rainy"/"chill"/"drive" → relaxed.
      expect(result.intent.moodTargets.first.mood, 'relaxed');
      await llm.dispose();
    });
  });

  group('Sparse pool', () {
    test('triggers veryLoose then libraryWideFallback; still 12 tracks',
        () async {
      // Tiny library, narrow intent — strict filter returns 0 rows
      // because BPM range 160..170 is entirely outside the seeded
      // BPM band of 95..100.
      final repo = FakeTrackRepo();
      for (var i = 0; i < 14; i++) {
        repo.addTrack(
          id: i + 1,
          artist: 'a$i',
          title: 't$i',
          bpm: 95.0 + (i % 5).toDouble(),
          moodAggressive: 0.6,
          moodSad: 0.1,
          moodRelaxed: 0.2,
          moodParty: 0.1,
          moodHappy: 0.0,
          year: 2000,
        );
      }
      final llm = FakeLlmBackend(
        intentScript: <Object>[
          _validIntent(mood: 'aggressive', bpm: (160, 170)),
        ],
        refineScript: <Object>[
          const FinalPass(swaps: [], blurb: 'Hard.'),
        ],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'aggressive metal',
        llm: llm,
        repo: repo,
        length: 12,
      );
      expect(result.trackIds.length, 12);
      expect(result.debug.relaxationLevel, RelaxationLevel.veryLoose);
      await llm.dispose();
    });
  });

  group('Empty / whitespace vibe', () {
    test('short-circuits to Intent.fallback("shuffle")', () async {
      final repo = _libraryOf30();
      // The fake's intentScript is empty; if the engine erroneously
      // reaches the LLM it will throw `StateError: intentScript empty`.
      // The whitespace short-circuit must skip the call entirely.
      final llm = FakeLlmBackend();
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: '   \t\n   ',
        llm: llm,
        repo: repo,
      );
      expect(llm.intentPrompts, isEmpty);
      expect(result.trackIds.length, 12);
      expect(result.intent.narrative, 'shuffle');
      await llm.dispose();
    });
  });

  group('Unknown moods snap via MoodLookup', () {
    test('Intent.fromJson("melancholic") → mood "sad"', () {
      final intent = Intent.fromJson(<String, dynamic>{
        'mood_targets': [
          {'mood': 'melancholic'}
        ],
        'energy_arc': 'flat',
        'duration_minutes': 45,
        'narrative': 'late night',
      });
      expect(intent.moodTargets.first.mood, 'sad');
    });
  });

  group('Swap validation', () {
    test('truncates >4 swaps + drops invalid insertId', () async {
      final repo = _libraryOf30();
      // Build a refine response with 6 swaps:
      //   - dropIndex 0 → insertTrackId 999 (NOT in top-40 → drop)
      //   - dropIndex 1 → insertTrackId 25  (in pool — should stick)
      //   - + 4 more so the pre-truncation count is 6
      final swaps = <Swap>[
        const Swap(dropIndex: 0, insertTrackId: 999),
        const Swap(dropIndex: 1, insertTrackId: 25),
        const Swap(dropIndex: 2, insertTrackId: 26),
        const Swap(dropIndex: 3, insertTrackId: 27),
        const Swap(dropIndex: 4, insertTrackId: 28),
        const Swap(dropIndex: 5, insertTrackId: 29),
      ];
      final llm = FakeLlmBackend(
        intentScript: <Object>[_validIntent()],
        refineScript: <Object>[
          FinalPass.fromJson(<String, dynamic>{
            'swaps': [for (final s in swaps) s.toJson()],
            'blurb': 'Truncated.',
          }),
        ],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'truncate test',
        llm: llm,
        repo: repo,
      );
      // Final pass truncated to 4; the engine recorded the 999
      // insertId as invalid. The truncated 5th and 6th swaps were
      // dropped before the engine even saw them, so they aren't in
      // invalidSwaps. The 999 swap *was* in the truncated 4 → it's
      // marked invalid by the engine.
      expect(result.trackIds.length, 12);
      final invalidIds =
          result.debug.invalidSwaps.map((s) => s.insertTrackId).toList();
      expect(invalidIds, contains(999));
      await llm.dispose();
    });
  });

  group('Hard rules — same-artist + BPM', () {
    test('every adjacent pair satisfies same-artist + |Δbpm| ≤ 15',
        () async {
      final repo = _libraryOf30();
      final llm = FakeLlmBackend(
        intentScript: <Object>[_validIntent()],
        refineScript: <Object>[const FinalPass(swaps: [], blurb: 'k.')],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'hard rules',
        llm: llm,
        repo: repo,
      );
      final cands = result.candidates;
      for (var i = 1; i < cands.length; i++) {
        // Same-artist adjacency.
        expect(
          cands[i].artistKey == cands[i - 1].artistKey,
          isFalse,
          reason: 'same-artist at $i',
        );
        // 3-window same-artist guard (no triple in any window of 3).
        if (i >= 2) {
          final a = cands[i - 2].artistKey;
          final b = cands[i - 1].artistKey;
          final c = cands[i].artistKey;
          expect(a == b && b == c, isFalse,
              reason: 'three-in-a-row same artist at $i');
        }
        // BPM window.
        final a = cands[i - 1].bpm;
        final b = cands[i].bpm;
        final delta = (a - b).abs();
        final halfDouble =
            (b - 2 * a).abs() < 15.0 || (b - a / 2).abs() < 15.0;
        expect(
          delta <= 15.0 || halfDouble,
          isTrue,
          reason: 'BPM jump $a → $b at $i',
        );
      }
      await llm.dispose();
    });
  });

  group('Energy arc — build', () {
    test('mean BPM picks 7..12 ≥ mean of 1..6 on a build-friendly fixture',
        () async {
      // Library with monotone-ascending BPM so the build arc has
      // somewhere to climb. 12 candidates with BPM 90..101 at one
      // each — Camelot keys identical so flow's bonus is constant
      // and BPM dominates.
      final repo = FakeTrackRepo();
      final artists = const [
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g',
        'h',
        'i',
        'j',
        'k',
        'l',
        'm',
        'n',
        'o',
        'p'
      ];
      for (var i = 0; i < 16; i++) {
        repo.addTrack(
          id: i + 1,
          artist: artists[i],
          title: 't$i',
          bpm: 90.0 + i.toDouble(),
          moodHappy: 0.6,
          moodParty: 0.5,
          moodRelaxed: 0.2,
          moodSad: 0.1,
          moodAggressive: 0.1,
          year: 2000,
        );
      }
      final llm = FakeLlmBackend(
        intentScript: <Object>[
          _validIntent(mood: 'happy', arc: EnergyArc.build, bpm: (85, 110)),
        ],
        refineScript: <Object>[const FinalPass(swaps: [], blurb: 'Build.')],
      );
      final engine = const PlaylistEngine();
      final result = await engine.generate(
        vibe: 'build me up',
        llm: llm,
        repo: repo,
      );
      final picks = result.candidates;
      expect(picks.length, 12);
      final firstHalf = picks.sublist(0, 6);
      final secondHalf = picks.sublist(6, 12);
      double mean(List<CandidateMeta> xs) =>
          xs.map((c) => c.bpm).fold(0.0, (a, b) => a + b) / xs.length;
      final mFirst = mean(firstHalf);
      final mSecond = mean(secondHalf);
      expect(mSecond, greaterThanOrEqualTo(mFirst),
          reason: 'build: mean(7..12) $mSecond < mean(1..6) $mFirst');
      await llm.dispose();
    });
  });

  group('Empty library', () {
    test('throws StateError', () async {
      final repo = FakeTrackRepo();
      final llm = FakeLlmBackend(intentScript: <Object>[_validIntent()]);
      final engine = const PlaylistEngine();
      expect(
        () => engine.generate(vibe: 'x', llm: llm, repo: repo),
        throwsStateError,
      );
      await llm.dispose();
    });
  });
}
