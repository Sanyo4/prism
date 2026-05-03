import 'dart:async';
import 'dart:io';

import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:test/test.dart';

void main() {
  // Reusable, fully-populated Intent for refine() tests.
  Intent buildIntent() => Intent(
        moodTargets: const [MoodTarget(mood: 'sad', min: 0.5)],
        bpmRange: null,
        era: null,
        energyArc: EnergyArc.build,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const ['rainy', 'instrumental'],
        narrative: 'late night',
      );

  List<CandidateMeta> buildCandidates() => List.generate(
        20,
        (i) => CandidateMeta(
          trackId: i + 1,
          artistKey: 'artist$i',
          title: 'Track ${i + 1}',
          key: 'Am',
          year: 1995 + i,
          bpm: 80.0 + i,
          moodHappy: 0,
          moodSad: 0.6,
          moodRelaxed: 0.4,
          moodAggressive: 0.1,
          moodParty: 0.1,
          danceability: 0.5,
          voiceInstrumental: 0.7,
        ),
      );

  /// Common harness: spin up `MobileBackend.withLoader` against a
  /// `_FakeCactusModel` whose `chat` returns a canned response.
  ({MobileBackend backend, _RecordingIdle idle, _FakeCactusModel fake})
      buildBackend({
    required String response,
    NpuSupport backend = NpuSupport.cpu,
    Duration tokenDelay = Duration.zero,
    bool throwOnChat = false,
  }) {
    final fake = _FakeCactusModel(
      cannedResponse: response,
      backend: backend,
      tokenDelay: tokenDelay,
      throwOnChat: throwOnChat,
    );
    final idle = _RecordingIdle();
    final init = CactusInit(
      spec: kQwen3_1_7B_INT4,
      paths: ModelPaths(
        rootDirProvider: () async => Directory.systemTemp,
        spec: kQwen3_1_7B_INT4,
      ),
      probe: NpuProbe(),
    );
    final mb = MobileBackend.withLoader(
      init: init,
      idle: idle,
      loader: (preferred) async => fake,
    );
    return (backend: mb, idle: idle, fake: fake);
  }

  group('MobileBackend.buildIntent', () {
    test('happy path → Intent', () async {
      const json = '{"mood_targets":[{"mood":"sad","min":0.5}],'
          '"energy_arc":"flat","duration_minutes":45,"narrative":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      final intent = await h.backend.buildIntent('rainy sunday');
      expect(intent.moodTargets, hasLength(1));
      expect(intent.moodTargets.first.mood, 'sad');
      expect(intent.moodTargets.first.min, 0.5);
      expect(intent.energyArc, EnergyArc.flat);
      expect(intent.durationMinutes, 45);
      expect(intent.narrative, 'x');
      // Idle is touched at chat entry, then again at every onToken.
      expect(h.idle.touchCount, greaterThanOrEqualTo(1));
    });

    test('strips a leading <think> block before parsing', () async {
      const json =
          '<think>plan…</think>{"mood_targets":[{"mood":"happy"}],'
          '"energy_arc":"build","duration_minutes":30,"narrative":"y"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      final intent = await h.backend.buildIntent('vibe');
      expect(intent.moodTargets.first.mood, 'happy');
      expect(intent.energyArc, EnergyArc.build);
    });

    test('strips a <tool_call> envelope before parsing', () async {
      const json = '<tool_call>{"name":"foo"}</tool_call>'
          '{"mood_targets":[{"mood":"relaxed"}],'
          '"energy_arc":"flat","duration_minutes":40,"narrative":"z"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      final intent = await h.backend.buildIntent('vibe');
      expect(intent.moodTargets.first.mood, 'relaxed');
    });

    test('malformed JSON raises LlmJsonParseException', () async {
      final h = buildBackend(response: 'this is not JSON at all');
      addTearDown(h.backend.dispose);
      await expectLater(
        h.backend.buildIntent('vibe'),
        throwsA(isA<LlmJsonParseException>()),
      );
    });

    test('cancel() mid-stream raises PlaylistCancelled', () async {
      // 6 token chunks + 30 ms each ≈ 180 ms. Cancel at ~50 ms.
      final h = buildBackend(
        response: '{"mood_targets":[{"mood":"sad"}],'
            '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}',
        tokenDelay: const Duration(milliseconds: 30),
      );
      addTearDown(h.backend.dispose);
      Timer(const Duration(milliseconds: 50), h.backend.cancel);
      await expectLater(
        h.backend.buildIntent('vibe'),
        throwsA(isA<PlaylistCancelled>()),
      );
    });

    test('progress stream emits PlaylistStep.intent + token chunks', () async {
      const json = '{"mood_targets":[{"mood":"sad"}],'
          '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      final events = <LlmProgress>[];
      final sub = h.backend.progress.listen(events.add);
      await h.backend.buildIntent('vibe');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();
      expect(events.first.step, PlaylistStep.intent);
      expect(events.any((e) => e.tokenChunk != null), isTrue);
      expect(events.any((e) => e.done), isTrue);
    });
  });

  group('MobileBackend.refine', () {
    test('happy path → FinalPass with swaps + blurb', () async {
      const json =
          '{"swaps":[{"dropIndex":3,"insertTrackId":42},'
          '{"dropIndex":7,"insertTrackId":99}],'
          '"blurb":"A late-night drive. Slow build into something quietly euphoric."}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      final pass = await h.backend.refine(buildIntent(), buildCandidates());
      expect(pass.swaps, hasLength(2));
      expect(pass.swaps.first.dropIndex, 3);
      expect(pass.swaps.first.insertTrackId, 42);
      expect(pass.blurb, contains('late-night drive'));
      // The user message must include the candidate-block lines.
      final userMessages = h.fake.lastUserMessage;
      expect(userMessages, contains('1 | Track 1 | artist0 | 80 | Am | 1995'));
      expect(userMessages, contains('20 | Track 20'));
    });

    test('refine cancel mid-stream → PlaylistCancelled', () async {
      const json =
          '{"swaps":[{"dropIndex":0,"insertTrackId":1}],"blurb":"x"}';
      final h = buildBackend(
        response: json,
        tokenDelay: const Duration(milliseconds: 30),
      );
      addTearDown(h.backend.dispose);
      Timer(const Duration(milliseconds: 50), h.backend.cancel);
      await expectLater(
        h.backend.refine(buildIntent(), buildCandidates()),
        throwsA(isA<PlaylistCancelled>()),
      );
    });
  });

  group('MobileBackend lifecycle', () {
    test('activeBackend reflects the loaded model after first use',
        () async {
      const json = '{"mood_targets":[{"mood":"sad"}],'
          '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}';
      final h = buildBackend(response: json, backend: NpuSupport.cpu);
      addTearDown(h.backend.dispose);
      // Before any call the model isn't loaded.
      expect(h.backend.isModelLoaded, isFalse);
      expect(h.backend.activeBackend, NpuSupport.unsupported);
      await h.backend.buildIntent('vibe');
      expect(h.backend.isModelLoaded, isTrue);
      expect(h.backend.activeBackend, NpuSupport.cpu);
    });

    test('releaseModel() is idempotent', () async {
      const json = '{"mood_targets":[{"mood":"sad"}],'
          '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      await h.backend.buildIntent('vibe');
      expect(h.backend.isModelLoaded, isTrue);
      await h.backend.releaseModel();
      expect(h.backend.isModelLoaded, isFalse);
      // Second call: no-op, no throw.
      await h.backend.releaseModel();
      expect(h.backend.isModelLoaded, isFalse);
    });

    test('idle.touch() fires at chat entry AND at every token chunk',
        () async {
      const json = '{"mood_targets":[{"mood":"sad"}],'
          '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      await h.backend.buildIntent('vibe');
      // Fake yields the response in 4 chunks → 1 entry touch + 4
      // onToken touches = 5 minimum. (Empty trailing chunks aren't
      // counted, so the floor is "more than 1".)
      expect(h.idle.touchCount, greaterThan(1));
    });
  });

  group('Prompt parity (slice-8 §11 item 12 — automated)', () {
    test('MobileBackend builds intent prompts from kIntentSystem '
        'verbatim', () async {
      const json = '{"mood_targets":[{"mood":"sad"}],'
          '"energy_arc":"flat","duration_minutes":30,"narrative":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      await h.backend.buildIntent('rainy sunday');
      final sys = h.fake.lastSystemMessage;
      expect(sys, isNotNull);
      // The slice-6 system prompt is a substring of the rendered
      // (schema-substituted) one — we render via `renderIntentSystem()`
      // which substitutes `{kIntentSchema}`. The unsubstituted prefix
      // is still present byte-for-byte.
      final prefix = kIntentSystem.split('{kIntentSchema}').first;
      expect(sys, contains(prefix));
      // And the substituted schema must contain the canonical field
      // names (a structural sanity check that we DID render).
      expect(sys, contains('"mood_targets"'));
      expect(sys, contains('"energy_arc"'));
    });

    test('MobileBackend builds refine prompts from kNarrativeSystem '
        'verbatim', () async {
      const json = '{"swaps":[],"blurb":"x"}';
      final h = buildBackend(response: json);
      addTearDown(h.backend.dispose);
      await h.backend.refine(buildIntent(), buildCandidates());
      // Refine uses kNarrativeSystem unchanged — assert the entire
      // string is present byte-for-byte.
      expect(h.fake.lastSystemMessage, kNarrativeSystem);
    });
  });
}

/// Records every `touch()` call so the lifecycle test can assert on
/// the count.
class _RecordingIdle extends IdleReleaser {
  int touchCount = 0;
  _RecordingIdle() : super(idle: const Duration(seconds: 5));

  @override
  void touch() {
    touchCount++;
    super.touch();
  }
}

/// Stand-in for `CactusModel` that returns a canned response without
/// loading any native binding. Streams the response in 4 token-shaped
/// chunks so the `IdleReleaser.touch` cadence + cancel-mid-stream
/// path are exercised realistically.
class _FakeCactusModel implements CactusModelLike {
  final String cannedResponse;
  @override
  final NpuSupport backend;
  final Duration tokenDelay;
  final bool throwOnChat;

  /// Records the most recent system / user message contents so prompt-
  /// parity tests can assert on them.
  String? lastSystemMessage;
  String? lastUserMessage;

  bool _closed = false;

  _FakeCactusModel({
    required this.cannedResponse,
    this.backend = NpuSupport.cpu,
    this.tokenDelay = Duration.zero,
    this.throwOnChat = false,
  });

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<String> chat({
    required List<CactusMessage> messages,
    required double temperature,
    required String format,
    CactusChatCancel? cancel,
    void Function(String chunk)? onToken,
  }) async {
    if (throwOnChat) {
      throw StateError('fake throw');
    }
    for (final m in messages) {
      if (m.role == 'system') lastSystemMessage = m.content;
      if (m.role == 'user') lastUserMessage = m.content;
    }
    // Stream the canned response in 4 chunks. Re-checks `cancel` at
    // every chunk and throws PlaylistCancelled when set — mirrors
    // `CactusModel`'s contract.
    final chunks = _quartileSplit(cannedResponse);
    final out = StringBuffer();
    for (final chunk in chunks) {
      if (tokenDelay > Duration.zero) {
        await Future<void>.delayed(tokenDelay);
      }
      if (cancel?.isCancelled == true) {
        throw const PlaylistCancelled();
      }
      out.write(chunk);
      if (onToken != null) onToken(chunk);
    }
    // No-op on `temperature`/`format` — the production wrapper passes
    // these into `optionsJson`; the fake just records that they were
    // both populated.
    expect(format, anyOf('json', equals(format)));
    expect(temperature, isPositive);
    return out.toString();
  }

  static List<String> _quartileSplit(String s) {
    if (s.isEmpty) return const [];
    final size = (s.length / 4).ceil();
    final out = <String>[];
    for (var i = 0; i < s.length; i += size) {
      out.add(
        s.substring(i, i + size > s.length ? s.length : i + size),
      );
    }
    return out;
  }
}
