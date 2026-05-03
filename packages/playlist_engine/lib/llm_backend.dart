/// LLM backend port for slice 6's `PlaylistEngine`.
///
/// The engine speaks to LLMs through this two-method abstract — the
/// implementer (Ollama on desktop, Cactus on phone) handles transport,
/// streaming, schema-mode/JSON-mode fallback, and `<think>…</think>`
/// stripping. The engine never knows whether it's talking to HTTP, a
/// local FFI inference loop, or a fake.
///
/// **Spec deviation vs `docs/plans/slice-06-desktop-llm-playlists.md` §7**:
/// the plan sketches `refine(Intent, List<Track>)` against `Track`
/// from `prism_core`. `packages/playlist_engine` cannot import
/// `prism_core` (slice-5 §6 hard rule). Track A switches the
/// signature to `refine(Intent, List<CandidateMeta>)` — slice-5's
/// existing `CandidateMeta` already carries everything the
/// narrative prompt serializes (`id | title | artist | bpm | key |
/// year`). See `docs/notes/slice-06-doc-refresh.md` for the full
/// note.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'final_pass.dart';
import 'intent.dart';
import 'repo.dart';

/// Stages the `PlaylistEngine` advances through. UI binds a step
/// indicator to the `step` field of the most recent [LlmProgress].
enum PlaylistStep {
  /// Stage A — `LlmBackend.buildIntent` is decoding.
  intent,

  /// Stage B — repo SQL filter is selecting up to 200 candidates.
  pool,

  /// Stage C — centroid cosine ranks the pool down to 40.
  rank,

  /// Stage D — flow scorer greedy-orders 40 → 20.
  flow,

  /// Stage E — `LlmBackend.refine` is decoding.
  narrative,

  /// Pipeline complete; result handed off to caller.
  ready,
}

/// One token (or whole-pass) progress event from a backend.
@immutable
class LlmProgress {
  /// Which pipeline stage this event belongs to.
  final PlaylistStep step;

  /// Optional incremental token text. `null` for non-streaming
  /// passes (e.g. cache hits, fakes that emit once).
  final String? tokenChunk;

  /// True iff this is the terminal event of [step] (the LLM's
  /// `done: true` chunk for streaming, or the only chunk for
  /// non-streaming).
  final bool done;

  const LlmProgress({
    required this.step,
    this.tokenChunk,
    this.done = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LlmProgress &&
          other.step == step &&
          other.tokenChunk == tokenChunk &&
          other.done == done);

  @override
  int get hashCode => Object.hash(step, tokenChunk, done);

  @override
  String toString() => 'LlmProgress(step: $step, '
      'tokenChunk: ${tokenChunk == null ? "null" : "${tokenChunk!.length} chars"}, '
      'done: $done)';
}

/// LLM backend port. Two passes:
/// 1. [buildIntent] — vibe text → structured [Intent].
/// 2. [refine] — `(intent, ordered candidates) → [FinalPass]`.
///
/// [progress] is a broadcast stream of token-by-token progress. Non-
/// streaming backends emit a single `done: true` event per pass.
abstract class LlmBackend {
  /// Stage A: convert user free-text into a strict-JSON [Intent].
  /// Throws [LlmJsonParseException] when the model's output cannot
  /// be parsed/validated; `PlaylistEngine` retries up to 2 repair
  /// prompts before falling back to [Intent.fallback].
  Future<Intent> buildIntent(String prompt);

  /// Stage E: given the [intent] and the 20 ordered [candidates],
  /// return ≤4 swaps + a ≤2-sentence blurb. Throws
  /// [LlmJsonParseException] on unparseable output.
  Future<FinalPass> refine(Intent intent, List<CandidateMeta> candidates);

  /// Token-by-token progress fan-out. Must be a broadcast stream
  /// (multiple subscribers: progress card + debug log).
  Stream<LlmProgress> get progress;
}

/// Thrown by an [LlmBackend] when the model's raw output cannot be
/// repaired into a valid value-class. `PlaylistEngine` catches this
/// and emits a repair prompt that names [reason]. After two failures
/// the engine falls back to `Intent.fallback(vibe)`.
class LlmJsonParseException implements Exception {
  /// Human-readable rule violation, e.g.
  /// `'mood_targets[0].mood: "moody" not in enum'`.
  final String reason;

  /// Best-effort raw response text (post-fence-strip) for the
  /// repair prompt's quoted excerpt. May be `null` when the
  /// transport never assembled a body.
  final String? raw;

  const LlmJsonParseException(this.reason, {this.raw});

  @override
  String toString() {
    final r = raw == null ? '' : '\n--- raw ---\n$raw';
    return 'LlmJsonParseException: $reason$r';
  }
}

/// Thrown when the active LLM request was cancelled mid-flight (UI
/// closed the sheet → `CancelToken.cancel()` on the backend).
/// `PlaylistEngine.generate` propagates this to the caller; UI
/// suppresses on close.
class PlaylistCancelled implements Exception {
  const PlaylistCancelled();

  @override
  String toString() => 'PlaylistCancelled';
}
