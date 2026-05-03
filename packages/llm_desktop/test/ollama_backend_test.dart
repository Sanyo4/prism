import 'dart:async';

import 'package:dio/dio.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';
import 'package:prism_playlist_engine/intent.dart';
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:prism_playlist_engine/repo.dart';
import 'package:test/test.dart';

void main() {
  group('OllamaBackend.buildIntent', () {
    test('happy path: 3 chunks → assembled JSON → Intent', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {'role': 'assistant', 'content': '{"mood_targets":'},
              'done': false,
            },
            {
              'message': {'role': 'assistant', 'content': '[{"mood":"sad","min":0.5}],'},
              'done': false,
            },
            {
              'message': {
                'role': 'assistant',
                'content':
                    '"energy_arc":"flat","duration_minutes":45,"narrative":"x"}',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = await backend.buildIntent('rainy sunday');
      expect(intent.moodTargets, hasLength(1));
      expect(intent.moodTargets.first.mood, 'sad');
      expect(intent.moodTargets.first.min, 0.5);
      expect(intent.energyArc, EnergyArc.flat);
      expect(intent.durationMinutes, 45);
      expect(intent.narrative, 'x');
    });

    test('strips leading <think> reasoning before parsing', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {
                'role': 'assistant',
                'content':
                    '<think>I should answer in JSON.</think>{"mood_targets":[{"mood":"happy"}],"energy_arc":"build","duration_minutes":30,"narrative":"y"}',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = await backend.buildIntent('vibe');
      expect(intent.moodTargets.first.mood, 'happy');
      expect(intent.energyArc, EnergyArc.build);
    });

    test('strips ```json fences before parsing', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {
                'role': 'assistant',
                'content':
                    '```json\n{"mood_targets":[{"mood":"relaxed"}],"energy_arc":"flat","duration_minutes":40,"narrative":"z"}\n```',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = await backend.buildIntent('vibe');
      expect(intent.moodTargets.first.mood, 'relaxed');
    });

    test('malformed JSON raises LlmJsonParseException', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {
                'role': 'assistant',
                'content': 'this is not JSON at all',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      await expectLater(
        backend.buildIntent('vibe'),
        throwsA(isA<LlmJsonParseException>()),
      );
    });

    test(
        'falls back to format: "json" when schema-mode returns 400',
        () async {
      // First call (schema object) → 400; second call (format:
      // "json") → success. The fake records which `format` it
      // received.
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [], // first call: throws 400 instead.
          [
            {
              'message': {
                'role': 'assistant',
                'content':
                    '{"mood_targets":[{"mood":"sad"}],"energy_arc":"descend","duration_minutes":50,"narrative":"d"}',
              },
              'done': true,
            },
          ],
        ],
        throwOn: const [400, null], // index 0 → 400; index 1 → no throw.
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = await backend.buildIntent('vibe');
      expect(intent.moodTargets.first.mood, 'sad');
      expect(fake.chatCalls, 2);
      expect(fake.formatsSeen.first, isA<Map<dynamic, dynamic>>());
      expect(fake.formatsSeen[1], 'json');
    });

    test('non-cancel DioException propagates', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [[]],
        throwOn: const [500],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      await expectLater(
        backend.buildIntent('vibe'),
        throwsA(isA<DioException>()),
      );
    });

    test('cancel() mid-stream surfaces as PlaylistCancelled', () async {
      // The fake yields slowly; the test calls `cancel()` before
      // the second chunk arrives. The backend converts the dio
      // cancel exception into PlaylistCancelled.
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {'role': 'assistant', 'content': '{"a":'},
              'done': false,
            },
          ],
        ],
        cancelMidStream: true,
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final fut = backend.buildIntent('vibe');
      // Schedule the cancel after the first chunk arrives.
      Timer(const Duration(milliseconds: 10), backend.cancel);
      await expectLater(fut, throwsA(isA<PlaylistCancelled>()));
    });

    test('progress stream emits intent step + token chunks', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {'role': 'assistant', 'content': 'piece1'},
              'done': false,
            },
            {
              'message': {'role': 'assistant', 'content': 'piece2'},
              'done': false,
            },
            {
              'message': {
                'role': 'assistant',
                'content':
                    '{"mood_targets":[{"mood":"sad"}],"energy_arc":"flat","duration_minutes":30,"narrative":"x"}',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final events = <LlmProgress>[];
      final sub = backend.progress.listen(events.add);
      try {
        await backend.buildIntent('vibe');
      } catch (_) {
        // Final chunk is unparseable on its own — that's fine; we
        // only care that progress fanned out the early chunks.
      }
      // Drain any pending events.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();
      expect(events, isNotEmpty);
      expect(events.first.step, PlaylistStep.intent);
      // First emit is the kickoff (tokenChunk null), then piece1.
      expect(events.any((e) => e.tokenChunk == 'piece1'), isTrue);
      expect(events.any((e) => e.tokenChunk == 'piece2'), isTrue);
      expect(events.any((e) => e.done), isTrue);
    });
  });

  group('OllamaBackend.refine', () {
    test('happy path: ordered candidates → FinalPass with swaps + blurb',
        () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {
                'role': 'assistant',
                'content':
                    '{"swaps":[{"dropIndex":3,"insertTrackId":42},{"dropIndex":7,"insertTrackId":99}],"blurb":"A late-night drive. Slow build into something quietly euphoric."}',
              },
              'done': true,
            },
          ],
        ],
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = Intent(
        moodTargets: const [MoodTarget(mood: 'sad', min: 0.5)],
        bpmRange: null,
        era: null,
        energyArc: EnergyArc.build,
        durationMinutes: 45,
        seedTracks: const [],
        seedKeywords: const ['rainy', 'instrumental'],
        narrative: 'late night',
      );
      final candidates = List.generate(
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
      final pass = await backend.refine(intent, candidates);
      expect(pass.swaps, hasLength(2));
      expect(pass.swaps.first.dropIndex, 3);
      expect(pass.swaps.first.insertTrackId, 42);
      expect(pass.blurb, contains('late-night drive'));
      // Verify the user message passes the candidate block (one
      // line per candidate) — the fake captures it.
      expect(fake.lastUserMessage, contains('1 | Track 1 | artist0 | 80 | Am | 1995'));
      expect(fake.lastUserMessage, contains('20 | Track 20'));
      // Format must be "json" (per spec for refine).
      expect(fake.formatsSeen.last, 'json');
    });

    test('refine cancel mid-stream → PlaylistCancelled', () async {
      final fake = _FakeOllamaClient(
        chatChunks: const [
          [
            {
              'message': {'role': 'assistant', 'content': '{"swaps":'},
              'done': false,
            },
          ],
        ],
        cancelMidStream: true,
      );
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final intent = Intent(
        moodTargets: const [MoodTarget(mood: 'happy')],
        bpmRange: null,
        era: null,
        energyArc: EnergyArc.flat,
        durationMinutes: 30,
        seedTracks: const [],
        seedKeywords: const [],
        narrative: 'x',
      );
      final fut = backend.refine(intent, const []);
      Timer(const Duration(milliseconds: 10), backend.cancel);
      await expectLater(fut, throwsA(isA<PlaylistCancelled>()));
    });
  });

  group('OllamaBackend.health', () {
    test('model present → up', () async {
      final fake = _FakeOllamaClient(tagsList: const ['qwen3:1.7b']);
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final h = await backend.health();
      expect(h.status, OllamaHealthStatus.up);
    });

    test('model absent → upModelMissing with detail', () async {
      final fake = _FakeOllamaClient(tagsList: const ['llama3.2:3b']);
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final h = await backend.health();
      expect(h.status, OllamaHealthStatus.upModelMissing);
      expect(h.detail, contains('qwen3:1.7b'));
    });

    test('connection refused → down', () async {
      final fake = _FakeOllamaClient(tagsThrows: true);
      final backend = OllamaBackend(fake, config: OllamaConfig());
      addTearDown(backend.dispose);
      final h = await backend.health();
      expect(h.status, OllamaHealthStatus.down);
      expect(h.detail, isNotNull);
    });
  });
}

/// Test double for [OllamaClient]. Subclassing keeps the type the
/// backend expects; we override only the methods we exercise. The
/// real dio is replaced with a stub that's never touched.
class _FakeOllamaClient extends OllamaClient {
  /// One inner list per `chat` call; each inner list is the ndjson
  /// chunks to yield in order.
  final List<List<Map<String, Object?>>> chatChunks;

  /// Per-call status code to throw before yielding (null = no throw).
  final List<int?>? throwOn;

  /// When true, the fake yields the first chunk then waits for an
  /// external `CancelToken.cancel()` before completing — used for
  /// the cancel-mid-stream tests.
  final bool cancelMidStream;

  /// /api/tags response (used by `health()`).
  final List<String> tagsList;

  /// When true, `tags()` throws a DioException(connectionError).
  final bool tagsThrows;

  /// Records each `format` argument seen on `chat()` so tests can
  /// assert schema-vs-string fallback.
  final List<Object?> formatsSeen = [];

  /// Records the user message of the last `chat()` call.
  String? lastUserMessage;

  /// Number of `chat()` invocations, for fallback assertion.
  int chatCalls = 0;

  _FakeOllamaClient({
    this.chatChunks = const [],
    this.throwOn,
    this.cancelMidStream = false,
    this.tagsList = const [],
    this.tagsThrows = false,
  }) : super(
          config: OllamaConfig(),
          dio: Dio()..httpClientAdapter = _NoOpAdapter(),
        );

  @override
  Stream<Map<String, Object?>> chat({
    required String model,
    required List<Map<String, Object?>> messages,
    Map<String, Object?>? options,
    Object? format,
    String? keepAlive,
    CancelToken? cancelToken,
  }) async* {
    final callIdx = chatCalls;
    chatCalls += 1;
    formatsSeen.add(format);
    // Capture the last user message for serialization assertions.
    for (final m in messages.reversed) {
      if (m['role'] == 'user' && m['content'] is String) {
        lastUserMessage = m['content'] as String;
        break;
      }
    }

    final maybeStatus =
        (throwOn != null && callIdx < throwOn!.length) ? throwOn![callIdx] : null;
    if (maybeStatus != null) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/chat'),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: RequestOptions(path: '/api/chat'),
          statusCode: maybeStatus,
        ),
      );
    }

    final chunks = callIdx < chatChunks.length
        ? chatChunks[callIdx]
        : const <Map<String, Object?>>[];
    for (var i = 0; i < chunks.length; i++) {
      yield chunks[i];
      if (cancelMidStream && i == 0) {
        // Wait for cancellation; if it arrives, surface as a dio
        // cancel exception so the backend's normal handling fires.
        for (var w = 0; w < 50; w++) {
          if (cancelToken != null && cancelToken.isCancelled) {
            throw DioException(
              requestOptions: RequestOptions(path: '/api/chat'),
              type: DioExceptionType.cancel,
              error: 'cancelled',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    }
  }

  @override
  Future<List<String>> tags() async {
    if (tagsThrows) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/tags'),
        type: DioExceptionType.connectionError,
        message: 'connection refused',
      );
    }
    return tagsList;
  }
}

/// Adapter that satisfies the Dio constructor's contract but is
/// never actually invoked (the fake overrides `chat` / `tags` before
/// reaching dio). If something does call it the test fails loudly.
class _NoOpAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    throw StateError(
      'Fake OllamaClient should not have hit the network: ${options.path}',
    );
  }

  @override
  void close({bool force = false}) {}
}

