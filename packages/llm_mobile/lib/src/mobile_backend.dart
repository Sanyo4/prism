/// `MobileBackend` — Cactus-backed `LlmBackend` implementation.
///
/// Mirrors slice-6's `OllamaBackend` byte-for-byte at the
/// progress-stream + repair + raise points so the slice-6
/// `LlmProgressCard` and `PlaylistEngine` repair loop work unchanged.
///
/// Uniqueness vs Ollama backend:
///  - Lazy load: model handle is acquired on the first `buildIntent`
///    or `refine` call and cached. `releaseModel()` clears it; the
///    next call reloads transparently.
///  - `IdleReleaser.touch()` fires at every chat entry AND at every
///    `onToken` chunk so a 30-second narrative pass doesn't trigger
///    a release mid-flight (slice-8 §10 risk 12).
///  - On weights-missing on disk → throw `ModelMissing` so Track B's
///    UI catches and switches to the download banner.
///  - `MobileJsonRepair` (not slice-6's `repairForJson`) cleans the
///    response — it adds `<tool_call>` envelope stripping and a
///    brace-balanced extractor.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

import 'cactus_init.dart';
import 'cactus_model.dart';
import 'idle_releaser.dart';
import 'mobile_json_repair.dart';
import 'model_spec.dart';
import 'npu_detect.dart';

/// Cactus-backed `LlmBackend`. Construct one per Android process.
class MobileBackend implements LlmBackend {
  final CactusInit init;
  final IdleReleaser idle;
  final CactusModelSpec spec;

  /// Cached active handle. Cleared by `releaseModel()` and on
  /// `init.load` failure.
  CactusModelLike? _model;

  /// Active cancel token for the in-flight `chat()`. Mirrors
  /// `OllamaBackend._activeCancel` so memory-pressure abort works.
  CactusChatCancel? _activeCancel;

  /// Broadcast progress controller — `LlmProgressCard` listens.
  final StreamController<LlmProgress> _progress =
      StreamController<LlmProgress>.broadcast();

  /// Test seam: when supplied, replaces the real `init.load` step
  /// with a callback returning a fake `CactusModelLike`. Production
  /// callers leave this null; `init.load(NpuSupport.cpu)` runs.
  final Future<CactusModelLike> Function(NpuSupport preferred)? _loadOverride;

  /// Production constructor. Production callers pass `init` and
  /// `idle`. Spec defaults to the pinned `kQwen3_1_7B_INT4`.
  MobileBackend({
    required this.init,
    required this.idle,
    CactusModelSpec? spec,
  })  : spec = spec ?? kQwen3_1_7B_INT4,
        _loadOverride = null;

  /// Test-only constructor that injects a custom model loader. Used
  /// by `mobile_backend_test.dart` to swap in a fake `CactusModelLike`.
  ///
  /// `init` is still required (for `ModelMissing` / `CactusInitFailed`
  /// raise types) but its `load` method is bypassed.
  @visibleForTesting
  MobileBackend.withLoader({
    required this.init,
    required this.idle,
    required Future<CactusModelLike> Function(NpuSupport preferred) loader,
    CactusModelSpec? spec,
  })  : spec = spec ?? kQwen3_1_7B_INT4,
        _loadOverride = loader;

  @override
  Stream<LlmProgress> get progress => _progress.stream;

  /// Reflects what the loaded handle reports. `unsupported` until the
  /// first successful load; `cpu` or `npu` afterwards. UI subscribes
  /// once and re-reads after `releaseModel()` + reload.
  NpuSupport get activeBackend =>
      _model?.backend ?? NpuSupport.unsupported;

  /// True iff a Cactus handle is currently held.
  bool get isModelLoaded => _model != null && !_model!.isClosed;

  @override
  Future<Intent> buildIntent(String prompt) async {
    idle.touch();
    _emit(PlaylistStep.intent, null);
    final cancel = _activeCancel = CactusChatCancel();

    try {
      final model = await _ensureLoaded();
      // Build messages with the slice-6-locked system prompt.
      // `renderIntentSystem()` substitutes the schema literal — we
      // call it explicitly here so the schema travels with the user
      // request, mirroring slice-6 Ollama's schema-mode call.
      final messages = <CactusMessage>[
        CactusMessage(role: 'system', content: renderIntentSystem()),
        CactusMessage(role: 'user', content: prompt),
      ];

      final raw = await model.chat(
        messages: messages,
        temperature: 0.1,
        format: 'json',
        cancel: cancel,
        onToken: (chunk) {
          if (chunk.isEmpty) return;
          idle.touch();
          _emit(PlaylistStep.intent, chunk);
        },
      );
      _emit(PlaylistStep.intent, null, done: true);

      final cleaned = MobileJsonRepair.clean(raw);
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
    idle.touch();
    _emit(PlaylistStep.narrative, null);
    final cancel = _activeCancel = CactusChatCancel();

    try {
      final model = await _ensureLoaded();
      final candidateBlock = formatCandidatesForRefine(candidates);
      final intentJson = jsonEncode(intent.toJson());
      final userMessage =
          'Intent:\n$intentJson\n\nCandidates (one per line, '
          '"id | title | artist | bpm | key | year"):\n$candidateBlock';

      final messages = <CactusMessage>[
        CactusMessage(role: 'system', content: kNarrativeSystem),
        CactusMessage(role: 'user', content: userMessage),
      ];

      final raw = await model.chat(
        messages: messages,
        temperature: 0.7,
        format: 'json',
        cancel: cancel,
        onToken: (chunk) {
          if (chunk.isEmpty) return;
          idle.touch();
          _emit(PlaylistStep.narrative, chunk);
        },
      );
      _emit(PlaylistStep.narrative, null, done: true);

      final cleaned = MobileJsonRepair.clean(raw);
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
    } finally {
      if (identical(_activeCancel, cancel)) {
        _activeCancel = null;
      }
    }
  }

  /// Cancel any in-flight chat. Idempotent; safe to call from a
  /// memory-pressure observer or a UI close handler.
  void cancel() {
    final c = _activeCancel;
    if (c != null && !c.isCancelled) {
      c.cancel();
    }
  }

  /// Drop the cached model handle (if any). Idempotent — calling on a
  /// not-loaded backend is a no-op. The next `buildIntent` / `refine`
  /// reloads from disk.
  Future<void> releaseModel() async {
    final m = _model;
    _model = null;
    if (m != null && !m.isClosed) {
      await m.close();
    }
  }

  /// Tear down. Cancels in-flight, releases the model, closes the
  /// progress controller. Idempotent. Long-lived providers should
  /// call this on disposal; tests use it via `addTearDown`.
  Future<void> dispose() async {
    cancel();
    await releaseModel();
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }

  /// Lazy-load. The first call grabs the handle; subsequent calls
  /// reuse it. On `init.load` failure, surfaces `ModelMissing` /
  /// `CactusInitFailed` directly — Track B's UI catches and routes.
  Future<CactusModelLike> _ensureLoaded() async {
    final cached = _model;
    if (cached != null && !cached.isClosed) {
      return cached;
    }
    final loader = _loadOverride;
    final model = loader != null
        ? await loader(NpuSupport.cpu)
        // Production: prefer NPU; `CactusInit.load` falls back to CPU
        // automatically on init failure.
        : await init.load(NpuSupport.npu);
    _model = model;
    return model;
  }

  void _emit(PlaylistStep step, String? token, {bool done = false}) {
    if (_progress.isClosed) return;
    _progress.add(LlmProgress(step: step, tokenChunk: token, done: done));
  }
}
