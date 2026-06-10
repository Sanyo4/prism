import 'package:meta/meta.dart';

/// Connection + behaviour knobs for the Ollama REST client.
///
/// Defaults mirror the `docs/plans/slice-06-desktop-llm-playlists.md`
/// spec: `http://localhost:11434`, `qwen3:1.7b`, `keep_alive 10m`,
/// `connectTimeout 5s`, and a zero `receiveTimeout` for streaming
/// endpoints (model-loading on a cold daemon can take 30+ s and the
/// receive timeout would otherwise abort that legit work).
@immutable
class OllamaConfig {
  /// Daemon base URL — `http://localhost:11434` per the Ollama
  /// docs default.
  final Uri baseUrl;

  /// Tag passed to `/api/chat` and `/api/generate` `model` field.
  final String model;

  /// `keep_alive` value passed on every chat/generate request — the
  /// model stays warm in RAM between `buildIntent` and `refine`
  /// (~2 s apart). 10 m is generous; the daemon evicts after this
  /// window of no calls. Slice plan §10 risk 8.
  final Duration keepAlive;

  /// Connect-phase timeout. Default 5 s — short enough for the
  /// Settings → LLM dot to flip red within the §11 item 6 budget.
  final Duration connectTimeout;

  /// Receive-phase timeout. Default `Duration.zero` (== "no
  /// receive timeout") so first-call cold-load isn't aborted. The
  /// engine's `CancelToken` is the cancellation contract — not a
  /// blanket timeout.
  final Duration receiveTimeout;

  /// Note: NOT a `const` constructor — `Uri.parse` is not const, so
  /// `_defaultBaseUrl` cannot be a const initializer. Callers
  /// don't need `const` here; `OllamaConfig()` is cheap.
  OllamaConfig({
    Uri? baseUrl,
    this.model = 'qwen3:1.7b',
    this.keepAlive = const Duration(minutes: 10),
    this.connectTimeout = const Duration(seconds: 5),
    this.receiveTimeout = Duration.zero,
  }) : baseUrl = baseUrl ?? _defaultBaseUrl;

  /// Default daemon URL. Resolved as a static-final so the field is
  /// initialised exactly once; `Uri.parse` rules out `const`.
  static final Uri _defaultBaseUrl = Uri.parse('http://localhost:11434');

  /// Returns a copy with the given fields replaced. Pass `null`
  /// (the default) to keep the existing value.
  OllamaConfig copyWith({
    Uri? baseUrl,
    String? model,
    Duration? keepAlive,
    Duration? connectTimeout,
    Duration? receiveTimeout,
  }) =>
      OllamaConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        keepAlive: keepAlive ?? this.keepAlive,
        connectTimeout: connectTimeout ?? this.connectTimeout,
        receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OllamaConfig &&
          other.baseUrl == baseUrl &&
          other.model == model &&
          other.keepAlive == keepAlive &&
          other.connectTimeout == connectTimeout &&
          other.receiveTimeout == receiveTimeout);

  @override
  int get hashCode => Object.hash(
        baseUrl,
        model,
        keepAlive,
        connectTimeout,
        receiveTimeout,
      );

  @override
  String toString() => 'OllamaConfig(baseUrl: $baseUrl, model: $model, '
      'keepAlive: ${keepAlive.inSeconds}s, '
      'connectTimeout: ${connectTimeout.inMilliseconds}ms, '
      'receiveTimeout: ${receiveTimeout.inMilliseconds}ms)';
}
