import 'dart:async';

import 'package:prism_playlist_engine/playlist_engine.dart';

/// Scriptable in-memory [LlmBackend] for engine tests.
///
/// `intentScript` and `refineScript` are queues of pre-canned
/// outcomes consumed in order. Each entry is one of:
///   - `Intent` / `FinalPass` — return as-is.
///   - `LlmJsonParseException` — throw verbatim. Used by the
///     repair-loop test (malformed → schema-invalid → valid).
///   - `Object` (any other) — wrapped as a generic Exception so
///     the engine's catch-all path is exercised.
///
/// `garbageOnly: true` makes both passes throw [LlmJsonParseException]
/// regardless of the script — the engine's `Intent.fallback` and
/// default-blurb degradation paths are exercised end-to-end.
class FakeLlmBackend implements LlmBackend {
  final List<Object> intentScript;
  final List<Object> refineScript;
  final bool garbageOnly;
  final StreamController<LlmProgress> _progress =
      StreamController<LlmProgress>.broadcast();

  /// Captured prompts so tests can assert the repair preamble fired.
  final List<String> intentPrompts = <String>[];
  int refineCalls = 0;

  FakeLlmBackend({
    List<Object>? intentScript,
    List<Object>? refineScript,
    this.garbageOnly = false,
  })  : intentScript = [...?intentScript],
        refineScript = [...?refineScript];

  @override
  Stream<LlmProgress> get progress => _progress.stream;

  @override
  Future<Intent> buildIntent(String prompt) async {
    intentPrompts.add(prompt);
    _progress.add(const LlmProgress(step: PlaylistStep.intent, done: true));
    if (garbageOnly) {
      throw const LlmJsonParseException(
        'fake garbage backend',
        raw: 'I am not JSON',
      );
    }
    if (intentScript.isEmpty) {
      throw StateError(
        'FakeLlmBackend: intentScript empty (call #${intentPrompts.length})',
      );
    }
    final next = intentScript.removeAt(0);
    if (next is Intent) return next;
    if (next is LlmJsonParseException) throw next;
    if (next is Exception) throw next;
    throw Exception('unexpected scripted value: $next');
  }

  @override
  Future<FinalPass> refine(
    Intent intent,
    List<CandidateMeta> candidates,
  ) async {
    refineCalls += 1;
    _progress.add(const LlmProgress(step: PlaylistStep.narrative, done: true));
    if (garbageOnly) {
      throw const LlmJsonParseException('fake garbage backend');
    }
    if (refineScript.isEmpty) {
      // Default: empty-swap blurb so the engine emits a default blurb.
      return const FinalPass(swaps: [], blurb: '');
    }
    final next = refineScript.removeAt(0);
    if (next is FinalPass) return next;
    if (next is LlmJsonParseException) throw next;
    if (next is Exception) throw next;
    throw Exception('unexpected scripted value: $next');
  }

  Future<void> dispose() async {
    await _progress.close();
  }
}
