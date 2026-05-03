/// Riverpod wiring for slice 6's `PlaylistEngine`.
///
/// Public surface:
///
/// - [trackRepoProvider] — async-resolved `TrackRepoImpl` (slice-6
///   extension of slice-5's `PlaylistRepoImpl`). Adds the SQL
///   candidate-pool query + keyword mean embedding helper.
/// - [playlistEngineProvider] — process-singleton `PlaylistEngine`.
/// - [newVibeProvider] — `AsyncNotifierProvider.family<NewVibeNotifier,
///   NewVibeState, String>`. The arg is the user's vibe text;
///   identity is `==` on the string so identical re-submissions
///   reuse the cached notifier. `ref.invalidate(newVibeProvider(vibe))`
///   regenerates.
///
/// Cancellation contract: the New Vibe sheet's close button calls
/// `ref.read(ollamaBackendProvider).cancel()` to abort the in-flight
/// `dio` request, then `ref.invalidate(newVibeProvider(vibe))` to
/// drop the notifier. The notifier translates `PlaylistCancelled`
/// into a final state with `cancelled: true`, no error toast.
///
/// **Riverpod 3.x family pattern**: the family builder takes a
/// `NotifierT Function(ArgT arg)` factory. We capture the vibe via
/// the constructor and re-emit it from `build()`. There's no
/// `FamilyAsyncNotifier` base class — Riverpod 3 dropped that name
/// in favour of the closure-captured pattern.
///
/// **Track A integration drift (as of Track C kickoff)**: the
/// `playlist_engine.dart` barrel has not yet been extended with
/// slice-6 exports (`intent.dart`, `final_pass.dart`,
/// `playlist_result.dart`, `llm_backend.dart`,
/// `playlist_engine_class.dart`). This file imports those modules
/// via deeper paths and flags every consumer with
/// `TODO(slice-6-integration)` so the user can tighten once the
/// barrel is appended.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
// TODO(slice-6-integration): flatten to the slice-6 barrel once
// Track A appends its exports. Today the package only re-exports
// the slice-5 surface from `playlist_engine.dart`.
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:prism_playlist_engine/playlist_engine.dart' as engine;
import 'package:prism_playlist_engine/playlist_engine_class.dart';
import 'package:prism_playlist_engine/playlist_result.dart';

import 'cache_db_providers.dart';
import 'llm_providers.dart';

/// Slice-6 `TrackRepo` adapter — extends slice-5's
/// `PlaylistRepoImpl` with the candidate-pool SQL + keyword mean.
final trackRepoProvider = FutureProvider<engine.TrackRepo>((ref) async {
  final cache = await ref.watch(cacheDbProvider.future);
  return TrackRepoImpl(cache);
});

/// Process-singleton `PlaylistEngine` — stateless aside from its
/// config (poolSize, rankedTop, flowedTop, FlowScorer).
final playlistEngineProvider =
    Provider<PlaylistEngine>((_) => const PlaylistEngine());

/// State the New Vibe sheet binds against. `step` advances through
/// every `PlaylistStep` value; `tokenPreview` is the last ~400 chars
/// of streamed LLM tokens (coalesced at 60 ms by the notifier);
/// `result` is non-null on `PlaylistStep.ready`; `cancelled` flips
/// true when the user closed the sheet mid-generate; `error` carries
/// the unhandled exception when the pipeline blew up on something
/// other than `PlaylistCancelled`.
class NewVibeState {
  /// Active pipeline stage. Starts at `PlaylistStep.intent`; the
  /// terminal value is `PlaylistStep.ready`.
  final PlaylistStep step;

  /// Last ~400 chars of streamed LLM tokens. The progress card
  /// renders these in a monospace `Text`. Empty until the backend
  /// emits its first chunk.
  final String tokenPreview;

  /// Non-null once the engine returns. The `Play` FAB and the 12
  /// rendered rows both read from here.
  final PlaylistResult? result;

  /// Set to a non-null value when the pipeline raised something
  /// other than `PlaylistCancelled`. The sheet renders this as a
  /// snackbar; the notifier's state stays in the last meaningful
  /// step value so the progress card can show "still on Stage X".
  final Object? error;

  /// True iff the sheet was closed mid-generate. The notifier
  /// catches `PlaylistCancelled` and sets this; UI suppresses any
  /// error toast on close.
  final bool cancelled;

  const NewVibeState({
    required this.step,
    this.tokenPreview = '',
    this.result,
    this.error,
    this.cancelled = false,
  });

  NewVibeState copyWith({
    PlaylistStep? step,
    String? tokenPreview,
    PlaylistResult? result,
    Object? error,
    bool? cancelled,
  }) =>
      NewVibeState(
        step: step ?? this.step,
        tokenPreview: tokenPreview ?? this.tokenPreview,
        result: result ?? this.result,
        error: error ?? this.error,
        cancelled: cancelled ?? this.cancelled,
      );
}

/// Notifier for one in-flight playlist generation. The arg is the
/// user's vibe text; identity is `==` on the string so identical
/// re-submissions reuse the cached notifier. `ref.invalidate` drops
/// the notifier and re-runs the pipeline.
final newVibeProvider = AsyncNotifierProvider.family<
    NewVibeNotifier, NewVibeState, String>(NewVibeNotifier.new);

class NewVibeNotifier extends AsyncNotifier<NewVibeState> {
  NewVibeNotifier(this.vibe);

  /// Family argument — the user's vibe text. Captured at
  /// construction time per Riverpod 3.x `AsyncNotifierProvider.family`
  /// shape.
  final String vibe;

  StreamSubscription<LlmProgress>? _progressSub;
  Timer? _coalesceTimer;
  String _pendingPreview = '';

  @override
  Future<NewVibeState> build() async {
    // Tear down on dispose — both the progress subscription and
    // the pending coalesce timer.
    ref.onDispose(() {
      _progressSub?.cancel();
      _coalesceTimer?.cancel();
    });

    final initial = NewVibeState(
      step: PlaylistStep.intent,
      tokenPreview: '',
    );
    state = AsyncData(initial);

    // Subscribe to progress events; coalesce token chunks into the
    // state at 60 ms.
    final backend = ref.read(ollamaBackendProvider);
    _progressSub = backend.progress.listen(_onProgress);

    final engineInst = ref.read(playlistEngineProvider);
    final repo = await ref.read(trackRepoProvider.future);

    try {
      // TODO(slice-6-integration): PlaylistEngine.generate signature
      // per slice plan §7: `generate({vibe, llm, repo, length=12})`.
      // Track A has shipped this method on
      // `playlist_engine_class.dart`; the import is via the deeper
      // path until the barrel is extended.
      final result = await engineInst.generate(
        vibe: vibe,
        llm: backend,
        repo: repo,
        length: 12,
      );
      _flushPreview();
      final finalState = (state.asData?.value ?? initial).copyWith(
        step: PlaylistStep.ready,
        result: result,
      );
      return finalState;
    } on PlaylistCancelled {
      _flushPreview();
      return (state.asData?.value ?? initial).copyWith(
        cancelled: true,
      );
    } catch (err) {
      _flushPreview();
      return (state.asData?.value ?? initial).copyWith(error: err);
    }
  }

  void _onProgress(LlmProgress event) {
    final current = state.asData?.value;
    if (current == null) return;
    // Step transitions surface immediately; token chunks coalesce.
    if (event.step != current.step) {
      _flushPreview();
      state = AsyncData(current.copyWith(step: event.step));
    }
    final chunk = event.tokenChunk;
    if (chunk != null && chunk.isNotEmpty) {
      _pendingPreview = _appendCoalesced(
        (state.asData?.value.tokenPreview ?? '') + chunk,
      );
      _coalesceTimer ??= Timer(const Duration(milliseconds: 60), _flushPreview);
    }
  }

  /// Trims [combined] to the last 400 chars so the progress card's
  /// `Text` doesn't grow unbounded under long generations.
  String _appendCoalesced(String combined) {
    const cap = 400;
    if (combined.length <= cap) return combined;
    return combined.substring(combined.length - cap);
  }

  void _flushPreview() {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    if (_pendingPreview.isEmpty) return;
    final current = state.asData?.value;
    if (current == null) {
      _pendingPreview = '';
      return;
    }
    state = AsyncData(current.copyWith(tokenPreview: _pendingPreview));
    _pendingPreview = '';
  }

  /// Cancels the in-flight Ollama request. Routes through the
  /// backend so its `CancelToken` aborts; the engine future then
  /// resolves with `PlaylistCancelled` and the `build` catch above
  /// flips `cancelled: true`.
  ///
  /// Track B made `OllamaBackend.cancel()` synchronous (sets the
  /// CancelToken; the underlying dio request aborts on the next
  /// `read`), so we don't await.
  void cancel() {
    final backend = ref.read(ollamaBackendProvider);
    backend.cancel();
  }
}
