import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'ndjson_decoder.dart';
import 'ollama_config.dart';

/// Thin Dio wrapper over the Ollama REST API.
///
/// Streaming endpoints (`/api/generate`, `/api/chat`, `/api/pull`)
/// return `ResponseType.stream`; the body is piped through
/// [NdjsonDecoder] so callers receive `Stream<Map<String, Object?>>`
/// — one ndjson object per yield. Cancellation is per-call via
/// [CancelToken]; the backend exposes a single `cancel()` to the
/// providers layer.
///
/// Why not `package:http_mock_adapter` for tests: slice 2 hand-rolled
/// a `_StubAdapter implements HttpClientAdapter`. Track B mirrors
/// that pattern (see `test/ollama_client_test.dart`) to keep
/// `dio` the only HTTP dep in the package.
class OllamaClient {
  /// Underlying dio instance; can be injected for tests
  /// (`Dio(BaseOptions(...))..httpClientAdapter = stub`).
  final Dio dio;

  /// Connection / model defaults baked into request bodies.
  final OllamaConfig config;

  /// Builds the client. When [dio] is null, constructs one with the
  /// timeouts from [config] applied to `BaseOptions`. Streaming
  /// endpoints override `responseType` and `receiveTimeout` per-call,
  /// so the base options here are the correct floor for the
  /// non-streaming `/api/tags` call.
  OllamaClient({required this.config, Dio? dio})
      : dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: config.baseUrl.toString(),
                connectTimeout: config.connectTimeout,
                receiveTimeout: config.receiveTimeout == Duration.zero
                    ? const Duration(seconds: 30)
                    : config.receiveTimeout,
                responseType: ResponseType.json,
                headers: const {
                  'Content-Type': 'application/json',
                  'Accept': 'application/x-ndjson, application/json',
                },
              ),
            );

  /// `POST /api/generate` — streaming text completion.
  ///
  /// Yields one decoded ndjson object per chunk; the final chunk has
  /// `done: true`. [format] is either the literal string `"json"` or
  /// a JSON Schema object (newer Ollama builds). [keepAlive] is
  /// passed verbatim — the backend formats it as `"<seconds>s"`.
  Stream<Map<String, Object?>> generate({
    required String model,
    required String prompt,
    Map<String, Object?>? options,
    Object? format,
    String? keepAlive,
    CancelToken? cancelToken,
  }) {
    final body = <String, Object?>{
      'model': model,
      'prompt': prompt,
      'stream': true,
      'options': ?options,
      'format': ?format,
      'keep_alive': ?keepAlive,
    };
    return _streamPost('/api/generate', body, cancelToken);
  }

  /// `POST /api/chat` — streaming chat completion.
  ///
  /// [messages] is the role/content pairs in the `qwen3:1.7b` chat
  /// template's expected order (typically `system`, `user`).
  /// Each yielded chunk has `message: {role, content}` plus `done`.
  Stream<Map<String, Object?>> chat({
    required String model,
    required List<Map<String, Object?>> messages,
    Map<String, Object?>? options,
    Object? format,
    String? keepAlive,
    CancelToken? cancelToken,
  }) {
    final body = <String, Object?>{
      'model': model,
      'messages': messages,
      'stream': true,
      'options': ?options,
      'format': ?format,
      'keep_alive': ?keepAlive,
    };
    return _streamPost('/api/chat', body, cancelToken);
  }

  /// `GET /api/tags` — installed models. Returns the `name` field of
  /// each entry (or `model` when `name` is absent — defensive across
  /// Ollama builds; Track-B doc-refresh notes both fields carry the
  /// same value when present).
  Future<List<String>> tags() async {
    final res = await dio.get<Map<String, Object?>>('/api/tags');
    final body = res.data;
    if (body == null) return const [];
    final raw = body['models'];
    if (raw is! List) return const [];
    final out = <String>[];
    for (final m in raw) {
      if (m is Map) {
        final name = m['name'] ?? m['model'];
        if (name is String && name.isNotEmpty) out.add(name);
      }
    }
    return out;
  }

  /// `POST /api/pull` — download a model. Streams progress objects
  /// of shape `{status, digest, total, completed}`. Calls
  /// [onProgress] with `completed/total` (0..1) when both are known.
  /// Returns when the daemon emits `status == "success"` or the
  /// stream closes.
  Future<void> pull(
    String model, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final body = <String, Object?>{'model': model, 'stream': true};
    final stream = _streamPost('/api/pull', body, cancelToken);
    await for (final chunk in stream) {
      if (onProgress != null) {
        final total = chunk['total'];
        final completed = chunk['completed'];
        if (total is num && completed is num && total > 0) {
          onProgress((completed / total).clamp(0.0, 1.0).toDouble());
        }
      }
      final status = chunk['status'];
      if (status == 'success') break;
    }
  }

  /// Common path for the three streaming endpoints. Sends [body] as
  /// JSON, configures `responseType: ResponseType.stream`, pipes
  /// through [NdjsonDecoder], and forwards [ct] for cancellation.
  Stream<Map<String, Object?>> _streamPost(
    String path,
    Map<String, Object?> body,
    CancelToken? ct,
  ) async* {
    final res = await dio.post<ResponseBody>(
      path,
      data: jsonEncode(body),
      cancelToken: ct,
      options: Options(
        responseType: ResponseType.stream,
        // Streaming model-load can take 30+ s on first call; the
        // CancelToken is the cancellation contract, not a blanket
        // receiveTimeout. Duration.zero == "no timeout" in dio 5.x.
        receiveTimeout: config.receiveTimeout,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/x-ndjson',
        },
      ),
    );
    final responseBody = res.data;
    if (responseBody == null) return;
    // ResponseBody.stream is Stream<Uint8List> in dio 5.x; pipe
    // straight into the ndjson decoder.
    yield* responseBody.stream.transform(const NdjsonDecoder());
  }
}
