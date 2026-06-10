/// `prism_llm_desktop` — Ollama REST client + `LlmBackend`
/// implementation for desktop.
///
/// Pure-Dart, no Flutter dependency. Imports `dart:async`,
/// `dart:convert`, `dart:typed_data`, `package:dio`, and Track A's
/// `package:prism_playlist_engine` types — nothing else (per slice 6
/// hard constraint, mirrored from slice-5's pure-engine discipline).
///
/// Public surface:
///   - [OllamaConfig]     — daemon URL, model tag, keep-alive, timeouts.
///   - [OllamaClient]     — thin dio wrapper for `/api/generate`,
///                          `/api/chat`, `/api/tags`, `/api/pull`.
///   - [OllamaBackend]    — implements [LlmBackend] (Track A);
///                          owns the active `CancelToken`, fans out
///                          `LlmProgress` events.
///   - [OllamaHealth] / [OllamaHealthStatus] — three-state status
///                          (up / upModelMissing / down) for the
///                          Settings → LLM dot.
///   - [NdjsonDecoder]    — exposed for callers wiring custom
///                          streaming endpoints (slice 8 reuse).
///   - [repairForJson]    — fence / `<think>` / prose stripper.
library;

export 'src/json_repair.dart' show repairForJson;
export 'src/ndjson_decoder.dart';
export 'src/ollama_backend.dart';
export 'src/ollama_client.dart';
export 'src/ollama_config.dart';
export 'src/ollama_health.dart';
