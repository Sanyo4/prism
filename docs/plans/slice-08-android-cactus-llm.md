# Slice 8 — Android Cactus LLM (`Qwen3-1.7B` INT4, `LlmBackend` parity)

## 1. Context

Slice 8 brings the slice-6 vibe-to-playlist flow to Android by supplying
a second `LlmBackend` implementation that runs the model **on-device,
offline, fully native**. Nothing about `PlaylistEngine`, `FlowScorer`,
`Camelot`, `TrackRepo`, or the two prompts changes. The interface
slice 6 locked is the contract slice 8 honors; the deliverable is a
provider swap plus the infrastructure to ship, store, load, and unload
a ~1 GB model gracefully on a phone.

**Cactus facts (verified against `github.com/cactus-compute/cactus`
and the HF card as of 2026-04-20):**

- Not `llama.cpp`. Custom zero-copy graph engine, ARM SIMD kernels,
  NPU acceleration. Does **not** read GGUF; weights are a Cactus-
  specific INT4 packed format from their conversion toolchain.
- Supported Qwen family: Qwen3-0.6B, Qwen3-1.7B, Qwen3.5-0.8B,
  Qwen3.5-2B. **Qwen2.5 unsupported.** Matches spec invariant.
- Pre-converted INT4 weights at `huggingface.co/Cactus-Compute/Qwen3-1.7B`;
  footprint ~1.0 GB weights + ~250 MB runtime working set.
- Flutter SDK at `/flutter/` — iOS, macOS, Android. **No Linux binaries**,
  which is why desktop uses Ollama (slice 6) and this slice is Android-only.
- OpenAI-compatible chat (`messages: [{role, content}]`), streaming
  token callback, native `<tool_call>…</tool_call>` parsing, `format: "json"` honored.
- Qualcomm/Google NPU support shipped March 2026. Pixel 9 Pro Fold
  (Tensor G4): NPU path when the runtime can bind it, else ARM SIMD
  CPU at proportionally lower tokens/s.

The slice assumes slices 1, 4, 5, 6 are done. Prompts are reused
byte-for-byte from `packages/playlist_engine/lib/prompts/`. Any on-
device-only repair behavior lives inside `MobileBackend`, never in
the shared prompt files.

## 2. Goals / Non-goals

**Goals**

- `packages/llm_mobile` — pure Dart; deps `cactus`, `dio`, `crypto`,
  `path_provider`, path dep on `playlist_engine`. Exposes
  `MobileBackend implements LlmBackend`, `CactusModel` (init/chat/close),
  `ModelDownloader` (progress + pause/resume), `NpuSupport` detection.
- Single runtime backend switch in `apps/mobile/lib/main.dart`:
  `Platform.isAndroid ? MobileBackend() : DesktopBackend()`. The
  `PlaylistEngine` call site is unchanged; `llmBackendProvider` is the seam.
- First-launch delivery: Settings → LLM shows a "Download model" banner
  when weights are absent. Resumable via `dio` Range requests, SHA256-
  verified, with size + ETA + pause/resume.
- Prompt parity: `buildIntent` uses slice-6 `kIntentSystem` + `kIntentSchema`
  unchanged; `refine` uses `kNarrativeSystem`. Qwen3-on-Cactus JSON quirks
  are cleaned by on-device `MobileJsonRepair` on the **response** side only.
- NPU-aware init with CPU fallback. On NPU bind failure (Tensor G4 quirk,
  unsupported tier), `CactusInit` retries `backend: cpu` and surfaces
  "Running on CPU — slower but works offline".
- Lifecycle: model loads on first AI-tab use, stays resident while the tab
  is foregrounded, released after 5 min idle or on
  `onTrimMemory(TRIM_MEMORY_RUNNING_LOW)`.
- Verification: coherent 12-track playlist on phone in airplane mode;
  quality qualitatively matches slice-6 Ollama output on the same prompt.

**Non-goals**

- **Cactus on Linux.** No Linux target; desktop keeps Ollama. Do not
  attempt source builds for Linux here or later.
- **Different / larger model on phone.** Locked to `Cactus-Compute/Qwen3-1.7B`;
  Qwen3.5-2B is out of scope.
- **GGUF anywhere.** No GGUF file, no conversion paths, no llama.cpp.
- **Tool-call invocation.** We parse `<tool_call>` defensively (token leakage
  in JSON mode) but never execute tools. Only `buildIntent` / `refine` flow.
- **User-editable prompts or temperature.** Same lock as slice 6.
- **Auto-download on first launch.** Banner only; 1 GB blind transfer is hostile.
- **Background / notification-backed downloads.** Runs while Settings → LLM is
  foregrounded; pause leaves a resumable `.partial`.
- **In-app Cactus updates.** SDK version pinned via `melos bootstrap`; no UI.
- **Per-device fine-tuning, LoRA, speculative decoding.**

## 3. Dependencies

Depends on: 6
Unblocks: —

Slice 6 contributes `LlmBackend`, `Intent`, `FinalPass`,
`PlaylistResult`, `PlaylistEngine`, the two prompt files, and the
`TrackRepo` adapter. Slice 4 contributes the SQLite cache and
embedding table the engine reads from. Slice 1 contributes `Track`,
`QueueService`, `PlaybackService` for end-to-end playback on phone.
Nothing downstream depends on slice 8 — this is a leaf slice in the
DAG and ships last in the LLM track.

## 4. Docs to refresh

Before any Dart, run every command and save a ≤5-line API summary
per entry in a scratch file. Cactus evolves fast — local memory is
almost certainly wrong.

### Cactus Flutter SDK

- `WebFetch https://github.com/cactus-compute/cactus` + `/blob/main/flutter/README.md`
  + `/tree/main/flutter/example` — confirm `flutter/` exists, package name,
  min Dart SDK, Android `minSdkVersion`, init options, streaming callback shape.
- Context7 `resolve-library-id libraryName: "cactus"` then `query-docs topic:
  "init chat stream tool_call close backend npu"` if pub.dev entry exists.
- **API summary reminder:** record the model-wrapper class name, init method
  (`init` | `load` | `create`), streaming callback signature, NPU/CPU selector
  field (`backend` | `accelerator` | `device`), release method (`close` |
  `dispose` | `release`). `cactus_init.dart` binds to these.

### HuggingFace model card

- `WebFetch https://huggingface.co/Cactus-Compute/Qwen3-1.7B` — file list,
  filenames, SHA256 digests.
- **Pin the revision**: record the commit SHA on refresh; hard-code in
  `CactusModelSpec.revision`. Never download from `main`.

### `dio` — resumable download, Range headers

- `resolve-library-id libraryName: "dio"` + `query-docs topic:
  "download onReceiveProgress range resumable CancelToken"`. `WebFetch
  https://pub.dev/packages/dio` to confirm the pinned 5.x API.
- **API summary reminder:** `Dio.download(url, savePath, options:
  Options(headers: {'Range': 'bytes=$from-'}), onReceiveProgress: ...)`.
  Total may be `-1` on partial responses — fall back to `Content-Range`.
  Pause via `CancelToken`.

### `crypto` (SHA256)

- `resolve-library-id libraryName: "crypto"` + `query-docs topic:
  "Sha256 streaming convert"`.
- **API summary reminder:** `Sha256().convert(bytes)` for small inputs;
  stream the 1 GB file via `AccumulatorSink<Digest>` +
  `Sha256().startChunkedConversion`.

### Android — large app-documents files + memory pressure

- `WebFetch https://developer.android.com/about/versions/15/behavior-changes-all`
  — confirm API 35 permits arbitrary-size files under
  `getApplicationDocumentsDirectory()` without scoped-storage prompts.
- `WebFetch https://developer.android.com/topic/performance/graphics/manage-memory`
  + `.../reference/android/content/ComponentCallbacks2` — `onTrimMemory`
  constants and how Flutter surfaces them
  (`WidgetsBindingObserver.didHaveMemoryPressure`).
- **API summary reminder:** app-private docs dir holds a 1 GB blob with
  zero user interaction. `didHaveMemoryPressure()` fires at
  `TRIM_MEMORY_RUNNING_LOW+`; we release the model there.

### `path_provider`

- `resolve-library-id libraryName: "path_provider"` + `query-docs topic:
  "getApplicationDocumentsDirectory android"`.
- **API summary reminder:** use `getApplicationDocumentsDirectory()` for
  weights; never `getExternalStorageDirectory()` (Syncthing / file managers
  can mutate it).

## 5. Architecture & data flow

```
 app start (Android)
    │
    ▼
 main.dart decides backend
    Platform.isAndroid → MobileBackend()
    else             → DesktopBackend()    ← slice 6, unchanged
    │
    ▼
 llmBackendProvider = Provider<LlmBackend>  ← single seam
    │
    ▼
 PlaylistEngine.generate(vibe, llm, repo, length: 12)
    same call site as slice 6 — no branching below here
    │
 ┌──┴──────────────────────────────────────────────────────┐
 │ MobileBackend.buildIntent(vibe) / refine(intent, picks) │
 │                                                         │
 │  (1) ensure weights on disk                             │
 │      └─ if missing → throw ModelMissing                 │
 │         UI catches → Settings → LLM banner              │
 │                                                         │
 │  (2) ensure CactusModel loaded                          │
 │      └─ CactusInit.tryNpu() → on fail → tryCpu()        │
 │         sets NpuSupport.{npu|cpu|unsupported}           │
 │                                                         │
 │  (3) chat(messages=[{system: kIntentSystem|kNarrative}, │
 │                     {user: vibe|serializedPicks}],      │
 │           format: "json",                               │
 │           temperature: 0.1 (intent) | 0.7 (refine),     │
 │           on_token: (chunk) => progress.add(...))       │
 │                                                         │
 │  (4) MobileJsonRepair.clean(text):                      │
 │      strip <think>…</think>                             │
 │      strip <tool_call>…</tool_call>                     │
 │      strip ```json fences                               │
 │      trim leading prose up to first '{'                 │
 │      then Intent.fromJson / FinalPass.fromJson          │
 │                                                         │
 │  (5) return Intent | FinalPass                          │
 └─────────────────────────────────────────────────────────┘

 First-use (weights absent) path:

    AI tab tap ─▶ PlaylistEngine throws ModelMissing
                 ▶ Settings banner "Download model (1.0 GB)"
                   ▶ dio download → .partial → SHA256 → rename
                                ▲          │
                                │ pause    │ resume (Range: bytes=N-)
                                └──────────┘

 Lifecycle:

    AI tab foregrounded  → load on first LLM call
    AI tab backgrounded  → idle timer 5 min → CactusModel.close()
    onTrimMemory(RUNNING_LOW+) → close immediately, cancel in-flight

 Package boundaries:

    packages/llm_mobile     ──implements──▶ LlmBackend (from engine)
        ├─ cactus dep
        ├─ dio dep (download only)
        ├─ crypto dep
        └─ knows nothing about DB / UI

    packages/playlist_engine unchanged
    packages/llm_desktop     unchanged (slice 6)
    apps/mobile              wires providers, UI banner, idle timer
```

## 6. File layout (new files only)

```
/packages/llm_mobile/pubspec.yaml
/packages/llm_mobile/lib/llm_mobile.dart                   # barrel
/packages/llm_mobile/lib/src/mobile_backend.dart           # implements LlmBackend
/packages/llm_mobile/lib/src/cactus_init.dart              # NPU→CPU trial, load, close
/packages/llm_mobile/lib/src/cactus_model.dart             # thin wrapper over Cactus SDK handle
/packages/llm_mobile/lib/src/model_download.dart           # dio download + resume + sha256
/packages/llm_mobile/lib/src/model_spec.dart               # url, revision, size, sha256, filename
/packages/llm_mobile/lib/src/npu_detect.dart               # runtime feature probe
/packages/llm_mobile/lib/src/mobile_json_repair.dart       # response cleanup (not prompt-side)
/packages/llm_mobile/lib/src/model_paths.dart              # resolves app-docs-dir path
/packages/llm_mobile/lib/src/idle_releaser.dart            # 5-min idle + onTrimMemory hook
/packages/llm_mobile/test/mobile_json_repair_test.dart
/packages/llm_mobile/test/model_download_test.dart         # DioAdapter-backed
/packages/llm_mobile/test/mobile_backend_test.dart         # fake CactusModel, parity spec
/apps/mobile/lib/providers/llm_providers_mobile.dart       # Android-only providers
/apps/mobile/lib/shell/settings_llm_section_mobile.dart    # download banner + NPU status row
/apps/mobile/lib/widgets/model_download_card.dart          # progress / ETA / pause-resume
/apps/mobile/lib/audio/memory_pressure_observer.dart       # didHaveMemoryPressure bridge
```

Edited additively:

- `apps/mobile/lib/main.dart` — platform switch for
  `llmBackendProvider`. Registers `MemoryPressureObserver`.
- `apps/mobile/lib/shell/settings_screen.dart` — on Android, swaps
  the slice-6 `SettingsLlmSection` for `SettingsLlmSectionMobile`.
- `apps/mobile/lib/providers/llm_providers.dart` — factors the
  backend provider into a `Provider<LlmBackend>` overridable by
  platform.
- `melos.yaml` — add `packages/llm_mobile`.
- `apps/mobile/pubspec.yaml` — conditional dep on `llm_mobile`
  (path) behind an `if Platform.isAndroid` gate is not possible in
  pubspec; the package is always a dep and its Android-only code is
  gated at runtime. Desktop builds pay the static analysis cost
  only — the `cactus` package is compatible with `dart analyze` on
  Linux even without platform binaries.

No changes to `packages/playlist_engine` or
`packages/llm_desktop`. No changes to `packages/core`,
`packages/playback`, or any slice-5 file.

## 7. Interfaces & key types

```dart
// packages/llm_mobile/lib/src/model_spec.dart
class CactusModelSpec {
  final Uri weightsUrl;     // huggingface.co/Cactus-Compute/Qwen3-1.7B/resolve/<rev>/weights.cactus
  final String revision;    // pinned HF commit SHA (see §4)
  final String fileName;    // e.g. "qwen3-1.7b-int4.cactus"
  final int    sizeBytes;   // exact, from HF revision
  final String sha256Hex;   // lowercase 64-char
}
const kQwen3_1_7B_INT4 = CactusModelSpec(
  weightsUrl: /* resolved at refresh time */,
  revision:   /* pinned at refresh time */,
  fileName:   'qwen3-1.7b-int4.cactus',
  sizeBytes:  /* pinned at refresh time */,
  sha256Hex:  /* pinned at refresh time */,
);

// packages/llm_mobile/lib/src/npu_detect.dart
enum NpuSupport { npu, cpu, unsupported }
class NpuProbe {
  /// npu = Cactus NPU bind OK; cpu = NPU unavailable, SIMD works;
  /// unsupported = not ARMv8.2-A+. Never throws.
  Future<NpuSupport> detect();
}

// packages/llm_mobile/lib/src/cactus_model.dart
class CactusModel {
  CactusModel._(this._handle);
  final Object _handle;
  NpuSupport get backend;
  bool get isClosed;
  /// Streaming JSON chat; [onToken] fires per decoded chunk; returns full text.
  Future<String> chat({
    required List<CactusMessage> messages,
    required double temperature,
    required String format,             // "json" for both passes
    CancelToken? cancel,
    void Function(String chunk)? onToken,
  });
  Future<void> close();
}
class CactusMessage { final String role; final String content; }

// packages/llm_mobile/lib/src/cactus_init.dart
class CactusInit {
  CactusInit(this._spec, this._paths, this._probe);
  /// Tries NPU first (when preferred=npu); on init error from backend bind,
  /// weight loader, or platform glue, retries with backend: cpu. Returns the
  /// loaded model and the actual backend.
  Future<CactusModel> load(NpuSupport preferred);
}

// packages/llm_mobile/lib/src/model_download.dart
class DownloadProgress {
  final int  receivedBytes, totalBytes;   // total may be -1
  final double bytesPerSecond;
  final Duration? eta;
  final DownloadPhase phase;
  final String? errorMessage;
}
enum DownloadPhase { connecting, downloading, verifying, done, paused, failed }
class ModelDownloader {
  ModelDownloader(this._dio, this._spec, this._paths);
  Stream<DownloadProgress> get progress;
  /// Resumes from .partial with Range: bytes=<existing>-; SHA256-verifies
  /// then renames .partial → final.
  Future<void> start();
  Future<void> pause();
  Future<bool> isComplete();               // final file exists + sha matches
}

// packages/llm_mobile/lib/src/mobile_json_repair.dart
class MobileJsonRepair {
  /// Strips <think>, <tool_call>, triple-backtick fences, and leading/trailing
  /// prose; returns the first balanced {…} block, or the input unchanged if
  /// none is found (caller raises LlmJsonParseException).
  static String clean(String raw);
}

// packages/llm_mobile/lib/src/mobile_backend.dart
class MobileBackend implements LlmBackend {
  MobileBackend({
    required CactusInit init,
    required IdleReleaser idle,
    CactusModelSpec spec = kQwen3_1_7B_INT4,
  });
  @override Future<Intent>   buildIntent(String vibe);
  @override Future<FinalPass> refine(Intent i, List<Track> candidates);
  @override Stream<LlmProgress> get progress;
  NpuSupport get activeBackend;            // npu | cpu | unsupported
  bool get isModelLoaded;
  Future<void> releaseModel();             // idempotent
}

// packages/llm_mobile/lib/src/idle_releaser.dart
class IdleReleaser {
  IdleReleaser({Duration idle = const Duration(minutes: 5)});
  void touch();                            // called at every chat()
  Stream<void> get shouldRelease;          // emits after idle elapsed
}
```

No changes to the `LlmBackend` interface from slice 6. `MobileBackend`
satisfies it with the same two futures and the same progress stream.
`progress` emits the six `PlaylistStep` values in the same order as
the Ollama backend so the slice-6 `LlmProgressCard` works unchanged.

## 8. Implementation steps

Ordered. Each step names its files and a single-line pass criterion.
Steps 3, 5, and 7 carry the most unknowns.

1. **Refresh docs (§4).** Save six ≤5-line API summaries. Pin Cactus
   package version, HF revision SHA, filename, size, SHA256 in `model_spec.dart`.
   **Pass:** summaries exist; `kQwen3_1_7B_INT4` fully populated.

2. **Create `packages/llm_mobile`.** Declare deps (`cactus`, `dio`, `crypto`,
   `path_provider`, path dep on `playlist_engine`). Register in `melos.yaml`;
   barrel re-exports public surface. **Pass:** `melos bootstrap` + `dart analyze` clean.

3. **`CactusModel` + `CactusInit`.** Bind SDK names from §4. `load(preferred)`
   tries NPU first, catches SDK-level init errors, retries once with `backend: cpu`;
   repeated failure throws `CactusInitFailed`.
   **Pass:** Pixel 9 Pro Fold loads on NPU; emulator without NPU loads on CPU;
   corrupt weights raise `CactusInitFailed`.

4. **`ModelDownloader`.** `dio.download(weightsUrl, '$path.partial', ...)`;
   resume via `Range: bytes=$existing-`; `pause()` cancels `CancelToken` without
   deleting `.partial`; on completion stream-hash via
   `Sha256().startChunkedConversion`, rename `.partial → final` on match, else
   delete and surface `DownloadPhase.failed` "checksum mismatch".
   **Pass:** `model_download_test.dart` with `MockAdapter` serves a 4-chunk body
   in two sessions; session 2 resumes from byte N; final SHA matches fixture.

5. **`MobileJsonRepair`.** Strip `<think>…</think>` (non-greedy, first only),
   `<tool_call>…</tool_call>`, ```` ```json ```` / ```` ``` ```` fences; locate
   first balanced `{…}` via a brace counter respecting strings + escapes.
   **Pass:** covers plain JSON, fenced JSON, `<think>` prefix, `<tool_call>`
   wrapper, prose tail, unterminated-brace passthrough.

6. **`MobileBackend.buildIntent`.** Ensure weights + model (else `ModelMissing`
   / `CactusInit.load`); `chat(messages=[{system:kIntentSystem},{user:vibe}],
   temperature: 0.1, format: "json", onToken: …)`; post-process with
   `MobileJsonRepair.clean` → `Intent.fromJson`. Import `kIntentSystem` from
   `packages/playlist_engine/lib/prompts/intent_prompt.dart` — never re-declare.
   `IdleReleaser.touch()` at entry.
   **Pass:** fake `CactusModel` returns slice-6 example Intent JSON → equivalent `Intent`.

7. **`MobileBackend.refine`.** Same scaffolding with `kNarrativeSystem`,
   `temperature: 0.7`, slice-6 20-track serialization → `FinalPass`; invalid
   swap IDs dropped downstream by engine.
   **Pass:** fake LLM narrative JSON → `FinalPass` with ≤4 swaps + ≤240-char blurb.

8. **`IdleReleaser` + memory-pressure hook.** `memory_pressure_observer.dart`
   registers a `WidgetsBindingObserver` overriding `didHaveMemoryPressure` →
   `releaseModel()`. `IdleReleaser` debounces a timer, emits `shouldRelease`
   after 5 min; `MobileBackend` subscribes.
   **Pass:** `CactusModel.close()` fires 5 min after last generate;
   `adb shell am send-trim-memory <pid> RUNNING_LOW` releases within 2 s.

9. **Download banner UI.** `settings_llm_section_mobile.dart` checks
   `isComplete()` on mount; if false, renders `ModelDownloadCard` ("On-device LLM",
   "Required for offline vibe playlists", 1.0 GB, progress bar, ETA,
   Pause/Resume/Cancel). On completion → green "Ready" row + NPU dot
   (green NPU, yellow CPU, red unsupported).
   **Pass:** first launch shows banner; pause keeps partial; relaunch resumes
   from byte N; completion replaces banner with Ready row.

10. **Providers + platform switch.** `llm_providers.dart` exposes
    `llmBackendProvider = Provider<LlmBackend>`. Android scope override returns
    `mobileBackendProvider`; other platforms slice-6 `ollamaBackendProvider`.
    `main.dart` applies override via `ProviderScope(overrides: [...])`.
    **Pass:** widget test with fake override: slice-6 `NewVibeSheet` renders
    identical 12-track result.

11. **"Wi-Fi only" toggle.** Settings → LLM switch (default on); `start()`
    consults `connectivity_plus` only if on. Metered + toggle on → paused
    "Waiting for Wi-Fi". **Pass:** cellular paused; switching to Wi-Fi auto-resumes.

12. **Parity check harness.** Dev-only opt-in (not CI): three vibes through
    `MobileBackend` (phone) + `OllamaBackend` (laptop); compare `Intent`
    shapes (mood-target overlap ≥ 0.6; `energy_arc` same in ≥2/3 runs).
    **Pass:** harness runs; log captured in scratch; not committed.

13. **Run §11.** **Pass:** every verification item green.

## 9. Alternatives considered

**(a) `llama.cpp` via FFI.** Rejected on RAM (Qwen3-1.7B GGUF INT4 ~1.8 GB
resident vs Cactus ~1.25 GB; Cactus is ~10× more memory-efficient per context
via zero-copy + INT4-native kernels) and NPU (no first-class Tensor G4 /
Hexagon path; CPU-only defeats the reason to be on Android in 2026).
Reconsider if Cactus stops shipping.

**(b) MLC-LLM.** TVM-based with a real GPU/NPU story, but the Flutter binding
is thin and Android Qwen3 artifacts either lag Cactus or require manual
conversion. Slice-6 locks "same model both sides"; Cactus publishes pre-
converted weights. Reconsider if Cactus drops Qwen3 and MLC holds it.

**(c) Run Ollama on-device.** No Android build; packaging a daemon in the APK
(foreign-arch binary, foreground service, disk layout, permissions) is out
of scope. No supported path.

**(d) Hosted LLM API on phone only.** Rejected by `docs/spec.md` (fully local
invariant; airplane-mode test in §11 is load-bearing) and on UX consistency
with desktop Ollama.

**(e) Smaller model (Qwen3-0.6B).** Would halve weights, but slice 6 locked
Qwen3-1.7B as the cross-platform model and 0.6B's JSON reliability at
temperature 0.1 under `kIntentSchema` is unproven. Reconsider only if the
Pixel 9 Pro Fold cannot hold 1.7B alongside playback — unlikely at 12 GB RAM.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | First-run download over metered connection. | "Download on Wi-Fi only" toggle (default on). Metered + toggle on → `DownloadPhase.paused` with "Waiting for Wi-Fi"; automatic resume on Wi-Fi. User can explicitly disable the toggle to force download. |
| 2 | Insufficient free disk space on phone. | `ModelDownloader.start()` pre-checks `statFs(appDocsDir)`; needs `spec.sizeBytes + 256 MB` buffer. Fails before any byte transfers, with phase `failed` and message "Not enough space. Free at least 1.3 GB." |
| 3 | NPU init fails on Tensor G4 (driver quirk, specific Android patch). | `CactusInit.load(preferred: npu)` catches and retries `backend: cpu`. Settings → LLM surfaces a banner "Running on CPU — slower but works offline." `activeBackend` exposed for diagnostics. No auto-retry on subsequent launches; user can tap "Retry NPU" in Settings to clear the pin. |
| 4 | Partial download on app kill. | Downloader writes to `<file>.partial`. Next launch, `ModelDownloader.start()` detects existing `.partial`, re-issues `Range: bytes=<size>-`. If server rejects (weak validators, resource moved), the partial is deleted and the download restarts with a user-visible notice. |
| 5 | Cactus API version drift (new method names, changed signatures). | `packages/llm_mobile/pubspec.yaml` pins the exact version (caret-less). `cactus_init.dart` contains a single `// Cactus SDK vX.Y.Z bindings` block that future upgrades must edit. Update policy: bump the pin only alongside a fresh §4 doc refresh and a manual §11 run; no automatic bumps. |
| 6 | Memory pressure during generation. | `didHaveMemoryPressure` cancels the active `CancelToken`, calls `MobileBackend.releaseModel()`, raises `PlaylistCancelled` up to `NewVibeSheet`. Sheet shows "Memory tight — try again in a moment." Next invocation reloads. |
| 7 | Qwen3 emits `<tool_call>` tokens inside a JSON-format response. | `MobileJsonRepair.clean` strips the envelope before `Intent.fromJson` / `FinalPass.fromJson`. Defensive; we never invoke the tool. |
| 8 | SHA256 mismatch after full download. | Delete `.partial`; surface `DownloadPhase.failed` with "Checksum mismatch. Tap to retry." Three consecutive checksum failures pin the failure and recommend checking network stability. |
| 9 | Weights file mutated by something unexpected (user moved it). | On init, `CactusInit.load` verifies SHA256 of the final file once per app-process lifetime (cached across subsequent loads). Mismatch → `ModelMissing`; Settings banner returns; download can re-trigger. |
| 10 | Cactus NPU binding succeeds but tokens-per-second is unusably low (driver regression). | `MobileBackend` times the first intent generation; if wall-clock > 60 s, logs a warning in `debug.slowFirstCall`. Not a hard failure — slow is better than absent. Documented in §11 item 6. |
| 11 | Model load takes >10 s on cold start, user thinks app froze. | `LlmProgress.loading` step emitted before the first `intent` chunk; UI shows "Warming up…" spinner. Slice-6 `LlmProgressCard` already accepts a generic progress state. |
| 12 | Idle release fires mid-generation because user backgrounded the AI tab briefly. | `IdleReleaser.touch()` is called at every `chat()` entry *and* at every token chunk via `onToken`. A release only fires after 5 min of true silence. |
| 13 | User uninstalls and reinstalls — weights deleted with app docs dir. | Expected. Banner returns on next launch. The `.partial` and `.cactus` files are explicitly app-private per §4. |
| 14 | Parity divergence: Ollama produces schema-valid JSON where Cactus produces schema-invalid on the same prompt. | `MobileJsonRepair` handles the documented Qwen3-on-Cactus quirks (think / tool_call / fences). Beyond that, the slice-6 `PlaylistEngine` repair loop (up to 2 retries + `Intent.fallback`) still runs. `debug.repairCount` surfacing in the result card lets us measure drift. |
| 15 | Cactus returns the entire response as one chunk instead of streaming. | Acceptable; `MobileBackend.progress` emits a single `LlmProgress.intent(full)` with `done: true`. UI does not rely on fine-grained streaming. |

## 11. Verification

Run in order on a Pixel 9 Pro Fold in airplane mode except where noted.
Items 1–5 are slice-8 acceptance; 6–11 cover the risk matrix.

1. **Fresh install shows "Download model".** Debug APK on clean device →
   AI tab → Settings → LLM shows "Download model (1.0 GB)", Pause disabled, ETA blank.
2. **Download completes.** Wi-Fi + Download → card shows progress, MB/s, ETA;
   completion within expected wall-clock; Ready row + NPU dot replace the card.
3. **Resume after pause.** Pause at ~30%, kill app, reopen → card shows partial
   + Resume; resume finishes without re-transferring bytes 0..N.
4. **First vibe offline: coherent 12-track playlist.** Airplane mode → AI tab →
   "rainy Sunday morning, low BPM, no vocals". Within 60 s: 12 rows + blurb
   ≤ 2 sentences; spot-listen plausible; no party-BPM / vocal-pop outliers;
   `debug.repairCount` ≤ 1.
5. **Playback end-to-end offline.** Tracks 1–12 auto-advance; lockscreen
   shows art/title; airplane mode stays on.
6. **Quality parity with slice 6.** Disable airplane for this step only.
   Same vibe on laptop (Ollama) and phone (Cactus): both produce 12 + blurb
   within wall-clock; `Intent` overlap (same `energy_arc`, ≥60% mood-target
   overlap). Playlists need not be identical — both must be coherent.
7. **NPU↔CPU fallback.** Dev flag forces NPU throw → fallback logs; banner
   shows "Running on CPU"; generation completes within ~2× NPU baseline.
   Clearing flag → NPU returns.
8. **Wi-Fi-only enforcement.** Toggle on, cellular only → "Waiting for Wi-Fi";
   enabling Wi-Fi auto-resumes.
9. **Disk-space guard.** Free <1.3 GB → `DownloadPhase.failed` "Not enough
   space. Free at least 1.3 GB." No bytes transferred.
10. **Memory pressure.** `adb shell am send-trim-memory <pid> RUNNING_LOW` →
    `CactusModel.close()` log; next vibe reloads transparently.
11. **Idle release.** 6 min untouched after a generate → `CactusModel.close()`
    at 5-min mark; next generate reloads within seconds.
12. **Prompt parity lock.** Automated test asserts `MobileBackend` uses
    `kIntentSystem` + `kNarrativeSystem` from the slice-6 prompt files verbatim
    (no concatenation, no interpolation). Fails on divergence.

## 12. Definition of done

- [ ] `packages/llm_mobile` exists, depends only on `cactus`,
  `dio`, `crypto`, `path_provider`, and `playlist_engine`. No
  Flutter imports inside `/src/` beyond `WidgetsBindingObserver`
  use in the memory-pressure bridge, which lives in `apps/mobile/`.
- [ ] `MobileBackend implements LlmBackend` with exactly the two
  futures and one progress stream from slice 6. No new public
  methods on the interface.
- [ ] `kIntentSystem`, `kNarrativeSystem`, and `kIntentSchema` are
  imported verbatim from `packages/playlist_engine/lib/prompts/`
  in `MobileBackend`. No mobile-specific prompt file exists.
- [ ] On-device JSON repair lives in
  `mobile_json_repair.dart` and runs on the **response** only.
- [ ] `llmBackendProvider` is the single platform seam; `main.dart`
  overrides it for Android. `PlaylistEngine` construction and the
  `NewVibeSheet` call site are unchanged from slice 6.
- [ ] First launch on a fresh install surfaces a "Download model"
  banner; download is resumable across app kill; SHA256 mismatch
  forces a retry; successful download replaces the banner with a
  Ready row + NPU-status dot.
- [ ] `ModelDownloader` pre-checks free disk space and refuses
  with a clear message when below the `spec.sizeBytes + 256 MB`
  threshold.
- [ ] `CactusInit.load` prefers NPU and falls back to CPU on the
  first init failure. `MobileBackend.activeBackend` reflects
  reality. Settings shows the "Running on CPU" banner when CPU.
- [ ] Model is released after 5 min idle on the AI tab, on
  `didHaveMemoryPressure(TRIM_MEMORY_RUNNING_LOW+)`, and on
  explicit `MobileBackend.releaseModel()`. Subsequent calls
  transparently reload.
- [ ] Generating a 12-track playlist on the Pixel 9 Pro Fold in
  airplane mode from the vibe "rainy Sunday morning, low BPM, no
  vocals" returns within 60 s, produces a blurb ≤ 2 sentences,
  and plays end-to-end without advancing manually.
- [ ] Generated playlist quality on the phone is not measurably
  worse than the desktop slice-6 output on the same vibe (§11
  item 6 passes).
- [ ] No GGUF file, `llama.cpp` binding, or alternative model
  anywhere in `packages/llm_mobile`. Cactus weights only.
- [ ] No change to `packages/playlist_engine`,
  `packages/llm_desktop`, slice-5 radio, slice-4 ingest, or slice-1
  playback.
- [ ] §4 "Docs to refresh" commands were executed and the API-
  summary notes captured the Cactus SDK version, the HuggingFace
  revision SHA, and the SHA256 of the weights file before any
  Dart file in `packages/llm_mobile` was touched.
- [ ] No deferred-work sentinels — every unfinished item is either
  explicitly out of scope per §2 or linked to a later doc.
