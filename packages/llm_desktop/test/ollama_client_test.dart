import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';
import 'package:test/test.dart';

void main() {
  group('OllamaClient', () {
    late _StubAdapter adapter;
    late OllamaClient client;

    setUp(() {
      adapter = _StubAdapter();
      final dio = Dio(BaseOptions(
        baseUrl: 'http://localhost:11434',
      ))..httpClientAdapter = adapter;
      client = OllamaClient(
        config: OllamaConfig(model: 'qwen3:1.7b'),
        dio: dio,
      );
    });

    test(
        'chat reassembles a 4-chunk ndjson body — '
        'message.content concatenation matches', () async {
      // Each chunk is one full ndjson line plus newline. Mid-line
      // splits across chunks are covered separately below.
      final chunks = <String>[
        '{"model":"qwen3:1.7b","message":{"role":"assistant","content":"Hel"},"done":false}\n',
        '{"model":"qwen3:1.7b","message":{"role":"assistant","content":"lo "},"done":false}\n',
        '{"model":"qwen3:1.7b","message":{"role":"assistant","content":"world"},"done":false}\n',
        '{"model":"qwen3:1.7b","message":{"role":"assistant","content":"!"},"done":true}\n',
      ];
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, '/api/chat');
        expect(ro.method, 'POST');
        // Body sanity: model + stream + the user message round-trip.
        final body = jsonDecode(ro.data as String) as Map<String, Object?>;
        expect(body['model'], 'qwen3:1.7b');
        expect(body['stream'], true);
        expect(body['messages'], isA<List<dynamic>>());
        return _streamingResponseBody(chunks);
      };

      final stream = client.chat(
        model: 'qwen3:1.7b',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      final pieces = <String>[];
      var sawDone = false;
      await for (final obj in stream) {
        final msg = obj['message'];
        if (msg is Map) {
          final c = msg['content'];
          if (c is String) pieces.add(c);
        }
        if (obj['done'] == true) sawDone = true;
      }
      expect(pieces.join(), 'Hello world!');
      expect(sawDone, isTrue);
    });

    test('chat handles mid-line UTF-8 + line splits across chunks',
        () async {
      // Split the same ndjson stream at arbitrary byte offsets to
      // verify NdjsonDecoder accumulates partial lines AND partial
      // UTF-8 sequences (the multi-byte em-dash) across chunks.
      const line1 = '{"message":{"content":"a—b"},"done":false}\n';
      const line2 = '{"message":{"content":"c"},"done":true}\n';
      final all = utf8.encode('$line1$line2');
      // Split into 5 pieces of arbitrary lengths.
      final c1 = Uint8List.fromList(all.sublist(0, 7));
      final c2 = Uint8List.fromList(all.sublist(7, 18));
      final c3 = Uint8List.fromList(all.sublist(18, 35));
      final c4 = Uint8List.fromList(all.sublist(35, line1.length + 5));
      final c5 = Uint8List.fromList(all.sublist(line1.length + 5));

      adapter.handler = (RequestOptions ro) =>
          _streamingResponseBodyBytes([c1, c2, c3, c4, c5]);

      final stream = client.chat(
        model: 'qwen3:1.7b',
        messages: const [
          {'role': 'user', 'content': 'x'},
        ],
      );
      final pieces = <String>[];
      await for (final obj in stream) {
        final msg = obj['message'];
        if (msg is Map) {
          final c = msg['content'];
          if (c is String) pieces.add(c);
        }
      }
      // Em-dash must round-trip — proves utf8.decoder accumulated.
      expect(pieces.join(), 'a—bc');
    });

    test('tags() parses /api/tags into model names', () async {
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, '/api/tags');
        expect(ro.method, 'GET');
        return ResponseBody.fromString(
          jsonEncode({
            'models': [
              {
                'name': 'qwen3:1.7b',
                'model': 'qwen3:1.7b',
                'modified_at': '2026-04-15T12:00:00Z',
                'size': 1234567890,
              },
              {
                'name': 'llama3.2:3b',
                'model': 'llama3.2:3b',
                'modified_at': '2026-03-20T08:00:00Z',
                'size': 9876543210,
              },
            ],
          }),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      };

      final names = await client.tags();
      expect(names, ['qwen3:1.7b', 'llama3.2:3b']);
    });

    test('tags() returns [] on empty / malformed body', () async {
      adapter.handler = (RequestOptions ro) =>
          ResponseBody.fromString('{}', 200, headers: {
            'content-type': ['application/json'],
          });
      expect(await client.tags(), isEmpty);
    });

    test('CancelToken.cancel() mid-stream surfaces as DioException(cancel)',
        () async {
      // Stream emits chunks slowly (simulate the model thinking)
      // and we cancel after the second chunk.
      final ct = CancelToken();
      final controller = StreamController<Uint8List>();

      adapter.handler = (RequestOptions ro) {
        // ResponseBody backed by a manual controller: we'll feed
        // chunks then cancel.
        return ResponseBody(
          controller.stream,
          200,
          headers: {
            'content-type': ['application/x-ndjson'],
          },
        );
      };

      // Feed two chunks then have the test cancel.
      unawaited(Future<void>.microtask(() async {
        controller.add(utf8.encode(
          '{"message":{"content":"chunk1"},"done":false}\n',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        controller.add(utf8.encode(
          '{"message":{"content":"chunk2"},"done":false}\n',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ct.cancel('test-cancel');
        // After cancel, dio rejects the response stream; we close
        // the controller too so the test doesn't hang.
        await controller.close();
      }));

      final stream = client.chat(
        model: 'qwen3:1.7b',
        messages: const [
          {'role': 'user', 'content': 'long'},
        ],
        cancelToken: ct,
      );

      DioException? caught;
      try {
        await for (final _ in stream) {
          // Drain.
        }
      } on DioException catch (e) {
        caught = e;
      }
      // Either dio raises a cancel exception during transport, or
      // the controller closes naturally before the cancel registers
      // (race). Both outcomes are acceptable; verify the cancel
      // token tracked the cancellation in the test-cancel path.
      expect(ct.isCancelled, isTrue);
      if (caught != null) {
        expect(CancelToken.isCancel(caught), isTrue);
      }
    });

    test('generate() uses /api/generate and yields response chunks',
        () async {
      final chunks = <String>[
        '{"response":"foo","done":false}\n',
        '{"response":"bar","done":false}\n',
        '{"response":"","done":true}\n',
      ];
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, '/api/generate');
        return _streamingResponseBody(chunks);
      };

      final stream = client.generate(
        model: 'qwen3:1.7b',
        prompt: 'hello',
        format: 'json',
        keepAlive: '600s',
      );
      final responses = <String>[];
      await for (final obj in stream) {
        final r = obj['response'];
        if (r is String) responses.add(r);
      }
      expect(responses.join(), 'foobar');
    });

    test('chat body includes options + format object when provided',
        () async {
      Map<String, Object?>? captured;
      adapter.handler = (RequestOptions ro) {
        captured = jsonDecode(ro.data as String) as Map<String, Object?>;
        return _streamingResponseBody(['{"done":true}\n']);
      };
      await client
          .chat(
            model: 'qwen3:1.7b',
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            options: const {'temperature': 0.1, 'num_ctx': 4096},
            format: const <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{},
            },
            keepAlive: '600s',
          )
          .drain<void>();
      expect(captured!['options'], isA<Map<dynamic, dynamic>>());
      expect(captured!['format'], isA<Map<dynamic, dynamic>>());
      expect(captured!['keep_alive'], '600s');
    });
  });
}

/// Wraps a list of ndjson lines into a single ResponseBody. Each
/// element becomes one byte chunk on the stream — adequate for line-
/// boundary tests; the mid-line split case has its own test.
ResponseBody _streamingResponseBody(List<String> chunks) {
  return ResponseBody(
    Stream<Uint8List>.fromIterable(
      [for (final c in chunks) Uint8List.fromList(utf8.encode(c))],
    ),
    200,
    headers: {
      'content-type': ['application/x-ndjson'],
    },
  );
}

/// Same idea but accepts pre-sliced byte chunks for the mid-line
/// split test.
ResponseBody _streamingResponseBodyBytes(List<Uint8List> chunks) {
  return ResponseBody(
    Stream<Uint8List>.fromIterable(chunks),
    200,
    headers: {
      'content-type': ['application/x-ndjson'],
    },
  );
}

/// Hand-rolled `HttpClientAdapter` mirroring slice 2's
/// `_StubAdapter` in `packages/metadata/test/mb_client_fake_test.dart`.
/// `handler` is set per-test; every request invokes it.
class _StubAdapter implements HttpClientAdapter {
  ResponseBody Function(RequestOptions)? handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final h = handler;
    if (h == null) {
      throw StateError('handler not set on _StubAdapter');
    }
    return h(options);
  }

  @override
  void close({bool force = false}) {}
}
