import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:prism_playlist_engine/final_pass.dart';
import 'package:prism_playlist_engine/intent.dart';
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:prism_playlist_engine/prompts/intent_prompt.dart';
import 'package:prism_playlist_engine/prompts/narrative_prompt.dart';
import 'package:prism_playlist_engine/repo.dart';

import 'json_repair.dart';
import 'ollama_client.dart';
import 'ollama_config.dart';
import 'ollama_health.dart';

/// Ollama-backed [LlmBackend] implementation. Drives `qwen3:1.7b` on
/// a local daemon; consumed by `PlaylistEngine.generate` exactly the
/// same way slice 8's Cactus backend will be on Android.
///
/// Pipeline contributions:
///  - [buildIntent] streams `/api/chat` with the strict-JSON Schema
///    `kIntentSchema` (fallback `format: "json"` on 400), then
///    `repairForJson` + `Intent.fromJson`.
///  - [refine] streams `/api/chat` with `format: "json"`, serializes
///    one candidate per line as `id | title | artist | bpm | key | year`,
///    then `repairForJson` + `FinalPass.fromJson`.
///  - [health] hits `/api/tags` and reports `up` /
///    `upModelMissing` / `down`.
///
/// Cancellation contract: every in-flight call holds a single
/// [CancelToken]. [cancel] cancels the active token; the next call
/// to [buildIntent] / [refine] starts a fresh one. The dio
/// `DioExceptionType.cancel` is converted to [PlaylistCancelled]
/// inside this class so the engine never sees `dio` types.
class OllamaBackend implements LlmBackend {
  final OllamaClient _client;

  /// Active configuration. Held by reference so callers (Settings →
  /// LLM URL field) can swap via providers; the next call picks up
  /// the new value.
  final OllamaConfig config;

  /// Visible to tests so they can assert that a cancelled token does
  /// not survive into the next call.
  CancelToken? _activeCancel;

  /// Broadcast progress stream. Both `LlmProgressCard` and the debug
  /// log listen; multiple subscribers are safe.
  final StreamController<LlmProgress> _progress =
      StreamController<LlmProgress>.broadcast();

  OllamaBackend(this._client, {required this.config});

  /// Cancels the active in-flight Ollama request, if any. Idempotent.
  /// Engine surface for the UI's "close sheet" / "cancel" affordance.
  void cancel() {
    final t = _activeCancel;
    if (t != null && !t.isCancelled) {
      t.cancel('user-cancel');
    }
  }

  /// Cleans up the broadcast controller. Long-lived providers should
  /// call this on disposal; tests use it after each case.
  Future<void> dispose() async {
    cancel();
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }

  @override
  Stream<LlmProgress> get progress => _progress.stream;

  @override
  Future<Intent> buildIntent(String prompt) async {
    _emit(PlaylistStep.intent, null);
    final cancel = _activeCancel = CancelToken();

    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': kIntentSystem},
      {'role': 'user', 'content': prompt},
    ];
    const options = <String, Object?>{
      'temperature': 0.1,
      'num_ctx': 4096,
      'seed': -1,
    };
    final keepAlive = _formatKeepAlive(config.keepAlive);

    try {
      // Try schema-mode first (newer builds). On 400 from the
      // daemon (the schema object isn't recognised), fall back to
      // the older `format: "json"` shape. The stream-acquisition
      // call site doesn't raise on its own — `dio.post` is awaited
      // inside `_streamPost`'s async generator, so the 4xx fires at
      // drain time. We therefore catch around the whole drain and
      // retry once with the fallback format.
      late final String raw;
      try {
        final schemaMap = jsonDecode(kIntentSchema) as Map<String, Object?>;
        final stream = _client.chat(
          model: config.model,
          messages: messages,
          options: options,
          format: schemaMap,
          keepAlive: keepAlive,
          cancelToken: cancel,
        );
        raw = await _drain(stream, PlaylistStep.intent, cancel);
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow; // bubble to outer.
        if (e.response?.statusCode != 400) rethrow;
        // Schema mode rejected — retry with the older string form.
        final stream = _client.chat(
          model: config.model,
          messages: messages,
          options: options,
          format: 'json',
          keepAlive: keepAlive,
          cancelToken: cancel,
        );
        raw = await _drain(stream, PlaylistStep.intent, cancel);
      } on FormatException catch (e) {
        // kIntentSchema isn't valid JSON — programmer error in
        // Track A. Rethrow as a parse exception so the engine
        // surfaces it rather than crashing.
        throw LlmJsonParseException(
          'kIntentSchema not valid JSON: ${e.message}',
        );
      }
      final cleaned = repairForJson(raw);
      try {
        final j = jsonDecode(cleaned);
        if (j is! Map<String, Object?>) {
          throw LlmJsonParseException(
            'top-level value is ${j.runtimeType}, expected Map',
            raw: raw,
          );
        }
        return Intent.fromJson(j);
      } on FormatException catch (e) {
        throw LlmJsonParseException(
          'jsonDecode failed: ${e.message}',
          raw: raw,
        );
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw const PlaylistCancelled();
      }
      // 400 path: fall-through retry already covered above; if a
      // non-cancel DioException reaches here, surface it.
      rethrow;
    } finally {
      if (identical(_activeCancel, cancel)) {
        _activeCancel = null;
      }
    }
  }

  @override
  Future<FinalPass> refine(
    Intent intent,
    List<CandidateMeta> candidates,
  ) async {
    _emit(PlaylistStep.narrative, null);
    final cancel = _activeCancel = CancelToken();

    final candidateBlock = _serializeCandidates(candidates);
    final intentJson = jsonEncode(intent.toJson());
    final userMessage =
        'Intent:\n$intentJson\n\nCandidates (one per line, '
        '"id | title | artist | bpm | key | year"):\n$candidateBlock';

    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': kNarrativeSystem},
      {'role': 'user', 'content': userMessage},
    ];
    const options = <String, Object?>{
      'temperature': 0.7,
      'num_ctx': 4096,
      'seed': -1,
    };

    try {
      final stream = _client.chat(
        model: config.model,
        messages: messages,
        options: options,
        format: 'json',
        keepAlive: _formatKeepAlive(config.keepAlive),
        cancelToken: cancel,
      );
      final raw = await _drain(stream, PlaylistStep.narrative, cancel);
      final cleaned = repairForJson(raw);
      try {
        final j = jsonDecode(cleaned);
        if (j is! Map<String, Object?>) {
          throw LlmJsonParseException(
            'top-level value is ${j.runtimeType}, expected Map',
            raw: raw,
          );
        }
        return FinalPass.fromJson(j);
      } on FormatException catch (e) {
        throw LlmJsonParseException(
          'jsonDecode failed: ${e.message}',
          raw: raw,
        );
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw const PlaylistCancelled();
      }
      rethrow;
    } finally {
      if (identical(_activeCancel, cancel)) {
        _activeCancel = null;
      }
    }
  }

  /// Two-step health check for Settings → LLM (§11 item 6).
  ///  - `/api/tags` succeeds AND model is in the list → [up].
  ///  - `/api/tags` succeeds but model absent → [upModelMissing].
  ///  - `/api/tags` errors (refused, timeout, ...) → [down].
  Future<OllamaHealth> health() async {
    try {
      final tags = await _client.tags();
      if (tags.contains(config.model)) {
        return const OllamaHealth(status: OllamaHealthStatus.up);
      }
      return OllamaHealth(
        status: OllamaHealthStatus.upModelMissing,
        detail: 'model "${config.model}" not pulled',
      );
    } on DioException catch (e) {
      return OllamaHealth(
        status: OllamaHealthStatus.down,
        detail: e.message ?? 'connection failed',
      );
    } catch (e) {
      // `tags()` shouldn't surface non-Dio errors but defend so
      // Settings never throws on a flaky network.
      return OllamaHealth(
        status: OllamaHealthStatus.down,
        detail: e.toString(),
      );
    }
  }

  /// Drains a chat stream into the assembled assistant text. Emits
  /// [LlmProgress] per non-empty content chunk so `LlmProgressCard`
  /// can tail-render. Stops on the `done: true` chunk OR when the
  /// stream closes naturally.
  Future<String> _drain(
    Stream<Map<String, Object?>> stream,
    PlaylistStep step,
    CancelToken cancel,
  ) async {
    final buf = StringBuffer();
    await for (final chunk in stream) {
      if (cancel.isCancelled) {
        // Exit early; CancelToken hasn't yet propagated through dio.
        throw const PlaylistCancelled();
      }
      // /api/chat → message.content; /api/generate → response.
      final msg = chunk['message'];
      String? piece;
      if (msg is Map) {
        final c = msg['content'];
        if (c is String) piece = c;
      }
      piece ??= chunk['response'] is String ? chunk['response'] as String : null;
      if (piece != null && piece.isNotEmpty) {
        buf.write(piece);
        _emit(step, piece);
      }
      if (chunk['done'] == true) {
        _emit(step, null, done: true);
        break;
      }
    }
    return buf.toString();
  }

  /// One row per candidate: `id | title | artist | bpm | key | year`.
  /// Mirrors the line shape `kNarrativeSystem` describes; missing
  /// year renders as `"—"` (em-dash). BPM rounded to int.
  String _serializeCandidates(List<CandidateMeta> candidates) {
    final out = StringBuffer();
    for (final c in candidates) {
      final year = c.year?.toString() ?? '—';
      final key = c.key.isEmpty ? '—' : c.key;
      out.writeln(
        '${c.trackId} | ${c.title} | ${c.artistKey} | ${c.bpm.round()} | $key | $year',
      );
    }
    return out.toString().trimRight();
  }

  /// `keep_alive` accepts string-with-unit (e.g. `"600s"`) per the
  /// Ollama docs (Track-B doc-refresh §4). We always emit seconds so
  /// callers passing arbitrary `Duration` values aren't rounded into
  /// minutes / hours.
  String _formatKeepAlive(Duration d) => '${d.inSeconds}s';

  void _emit(PlaylistStep step, String? token, {bool done = false}) {
    if (_progress.isClosed) return;
    _progress.add(LlmProgress(step: step, tokenChunk: token, done: done));
  }
}
