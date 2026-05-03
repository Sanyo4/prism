/// `prism_llm_mobile` — Cactus-backed `LlmBackend` implementation
/// for Android.
///
/// Pure-Dart wrapper over the Cactus 1.3.0 Flutter binding plus
/// a resumable, SHA256-verified weights downloader. The native side
/// runs only on Android arm64; Linux desktop falls through to slice
/// 6's Ollama backend per `apps/mobile`'s platform switch.
///
/// Public surface:
///  - [MobileBackend]      — implements `LlmBackend`; lazily loads a
///                            Cactus handle, fans out `LlmProgress`.
///  - [CactusInit]         — NPU→CPU trial loader; raises
///                            [ModelMissing] / [CactusInitFailed].
///  - [CactusModel]        — production wrapper over Cactus's FFI.
///  - [CactusModelLike]    — abstract chat interface for tests +
///                            mobile_backend injection.
///  - [CactusMessage]      — `{role, content}` payload.
///  - [CactusChatCancel]   — co-operative cancel token.
///  - [ModelDownloader]    — dio-backed resumable + SHA256-verified
///                            download with `Range:` resume.
///  - [DownloadProgress] / [DownloadPhase] — UI state shape for the
///                            download banner.
///  - [CactusModelSpec]    — manifest pinning HF revision + SHA256.
///  - [kQwen3_1_7B_INT4]   — populated pin (refresh 2026-05-03).
///  - [NpuProbe] / [NpuSupport] — runtime capability tag.
///  - [IdleReleaser]       — debounced 5-min idle-release timer.
///  - [ModelPaths]         — resolves on-disk paths under app docs.
///  - [MobileJsonRepair]   — response-side cleanup
///                            (`<think>`/`<tool_call>`/fences).
///
/// Track B (`apps/mobile`) imports this barrel and consumes
/// `MobileBackend`, `ModelDownloader`, the spec + the exception types.
library;

export 'src/cactus_init.dart' show CactusInit, ModelMissing, CactusInitFailed;
export 'src/cactus_model.dart'
    show CactusModel, CactusModelLike, CactusMessage, CactusChatCancel;
export 'src/idle_releaser.dart' show IdleReleaser;
export 'src/mobile_backend.dart' show MobileBackend;
export 'src/mobile_json_repair.dart' show MobileJsonRepair;
export 'src/model_download.dart'
    show ModelDownloader, DownloadProgress, DownloadPhase;
export 'src/model_paths.dart' show ModelPaths;
export 'src/model_spec.dart' show CactusModelSpec, kQwen3_1_7B_INT4;
export 'src/npu_detect.dart' show NpuProbe, NpuSupport;
