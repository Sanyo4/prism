/// Prism playlist engine — pure-Dart, platform-agnostic.
///
/// Slice 5 ships [RadioEngine] (seed-kNN + steer chips). Slice 6
/// adds [PlaylistEngine] beside it sharing [FlowScorer] and
/// [Camelot] without modification — the public surface here is the
/// API stability contract that protects that future work.
///
/// **Hard import constraints (slice 5 §6, locked through slice 6):**
///   - Imports only `dart:typed_data`, `dart:math`, `dart:async`,
///     `dart:convert`, `package:meta`, `package:collection`.
///   - Zero `package:flutter`, `dart:io`, `package:sqlite3`,
///     `package:prism_core`, `package:dio`.
///   - All storage access goes through the [PlaylistRepo] /
///     [TrackRepo] ports; `packages/core/lib/src/db/playlist_repo_impl.dart`
///     ships the SQLite-backed implementations.
///   - All LLM access goes through the [LlmBackend] port;
///     `packages/llm_desktop` (Track B) ships the Ollama
///     implementation; slice 8 will ship the Cactus implementation
///     for Android.
library;

// Slice-5 surface — preserved verbatim for back-compat. Slice-5 tests
// import these via the barrel; their public shape must not change.
export 'camelot.dart';
export 'chip_weights.dart';
export 'flow.dart';
export 'pick_result.dart';
export 'radio_engine.dart';
export 'radio_session.dart';
export 'repo.dart';
export 'steer_chip.dart';

// Slice-6 surface.
export 'final_pass.dart';
export 'intent.dart';
export 'llm_backend.dart';
export 'playlist_engine_class.dart';
export 'playlist_result.dart';
export 'prompts/intent_prompt.dart';
export 'prompts/mood_lookup.dart';
export 'prompts/narrative_prompt.dart';
