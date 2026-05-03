# Slice 8 — Doc refresh notes

Status snapshot for the slice-8 work. Track A (this file's author) covers
Cactus + dio + crypto + path_provider + HuggingFace pin. Track B will
append Android memory-pressure + connectivity sections below.

Date refreshed: 2026-05-03.

---

## Cactus (Flutter package on pub.dev)

**Package name resolved:** `cactus` (NOT `cactus_flutter`). Pub.dev
listing under publisher `cactuscompute.com` exposes the Flutter
binding as `cactus`.

**Latest published version:** `1.3.0` (4 months old as of refresh —
this is the most recent stable). Pin `cactus: 1.3.0` (caret-less per
slice-8 §10 risk 5: bump only with a fresh refresh + manual §11 run).

**SDK constraints:** pub.dev install page does not surface the exact
Dart/Flutter SDK floors. Cactus's GitHub `flutter/` directory's
`pubspec.yaml` returned 404 on raw fetch, so we cannot fully pin the
floor without a `pub get`. Project-wide we already require Dart
`^3.11.0`; Cactus 1.3.0 has been published against the same recent
Dart range so the workspace constraint is sufficient. Recheck on
upgrade.

**Platform support:** Android, iOS, macOS. **No Linux.** Confirms
slice 6's Ollama backend stays the desktop path.

**Android minSdkVersion:** README says "Android API 21+" without naming
`minSdkVersion`. Track B must verify in `apps/mobile/android/app/build.gradle`.

**API surface (from `flutter/README.md` + `llms.txt`):**

The Flutter binding exposes Dart FFI top-level functions — there is
NO `class CactusModel` in the package. The classes the pub.dev page
mentions (`CactusLM`, `CactusSTT`, `CactusRAG`) are higher-level
wrappers that the README surfaces only by example; the canonical
binding is the FFI surface.

  - `cactusInit(String modelPath, String? corpusDir, bool cacheIndex)
    → ModelHandle` — pointer-typedef return.
  - `cactusComplete(ModelHandle model, String messagesJson,
    String? optionsJson, String? toolsJson,
    void Function(String token, int tokenId)? callback)
    → String` — returns JSON-encoded result with fields
    `success`, `response`, `confidence`, `total_tokens`, etc.
  - `cactusDestroy(ModelHandle model) → void`
  - `cactusEmbed(ModelHandle model, String text, bool normalize)
    → Float32List`

Streaming callback signature: `void Function(String token, int tokenId)`.

**NPU/CPU selector:** there is no Dart-level `backend` field in
`cactusInit`. Cactus exposes `ComputeBackend::NPU` at the C++ graph
level, but the Flutter binding does not surface it as a parameter in
v1.3.0. NPU acceleration is gated behind a Cactus Pro key
(`CactusConfig.setProKey(...)`) per the pub.dev README excerpt.
**Implication for `CactusInit.load(NpuSupport preferred)`:** the
"NPU vs CPU" branching has no per-call selector to flip. We treat
NpuSupport as a *runtime probe* that records what the platform
*could* run rather than a literal selector — `MobileBackend.activeBackend`
reflects detection, not configuration. Track B's UI reads
`activeBackend` to badge "NPU available" / "CPU only". The retry-on-init-
failure path in `CactusInit.load` is preserved as a try/catch around
the single `cactusInit` call (which can still fail for reasons
unrelated to NPU — corrupt weights, OOM, missing native lib).

**JSON-mode / tool_call handling:** `optionsJson` accepts
`{"max_tokens", "temperature", "top_p", "min_p", "repetition_penalty",
"top_k", "stop_sequences", "include_stop_sequences", "force_tools",
"enable_thinking_if_supported", ...}`. There is **no `format: "json"`
option** the way Ollama exposes; we send `enable_thinking_if_supported:
false` and keep `temperature: 0.1` for intent / `0.7` for refine, and
rely on `MobileJsonRepair` to strip `<think>` / `<tool_call>` /
fences on the response side.

**Cancellation:** Cactus FFI does not expose a cancel handle in the
Flutter binding. The brief still wants a `CancelToken` plumbed
through `MobileBackend.chat` for memory-pressure abort —
implementation: cancellation is checked at every `onToken` callback
(throw `PlaylistCancelled` from inside the callback). The next call
will start a fresh handle.

---

## HuggingFace pin — Cactus-Compute/Qwen3-1.7B

- **Revision SHA (commit):** `51397eec167a109d41c0006d37e780b9c9b618e5`
- **Commit message:** "Upload v1.14"
- **Filename:** `weights/qwen3-1.7b-int4.zip`
- **sizeBytes:** `1006051493` (1.01 GB)
- **SHA256:** `a9d09c15110b2977f6b71d393bbad4f9991b5d59638c413ea07c63d2c28ca802`
  (sourced from the Git LFS pointer at the pinned revision; lowercase 64-char)
- **Resolve URL:** `https://huggingface.co/Cactus-Compute/Qwen3-1.7B/resolve/51397eec167a109d41c0006d37e780b9c9b618e5/weights/qwen3-1.7b-int4.zip`

The repo also publishes `weights/qwen3-1.7b-int8.zip` (1.73 GB). We
ship INT4 only per slice-8 §1 (footprint budget).

The file is a **.zip** archive — Cactus expects an unpacked weights
**directory** as `cactusInit`'s first argument, so `MobileBackend`'s
init path will need to extract the archive on first use. Track A's
package only verifies the archive's SHA256 and renames `.partial → final`;
the unzip + directory layout step is handled by `CactusInit.load`'s
weights-prep logic OR is deferred to Track B's first-run UI. **Open
question for Track B:** decide whether `ModelDownloader.start()` ends
at `qwen3-1.7b-int4.zip` (and Track B's UI orchestrates unzip), or
whether `CactusInit` autounzips on first load. Track A leaves
`isComplete()` to test only that the .zip is on disk + SHA256 matches.
Document this seam in the slice-8 plan if it isn't already.

---

## dio (HTTP client) — pinned to `^5.7.0`

API surface relevant to `model_download.dart`:

- `Dio.download(url, savePath, {options, onReceiveProgress,
  cancelToken, deleteOnError})` — the standard download entry.
- Range header for resume: pass via `Options(headers: {'Range':
  'bytes=$existing-'})`. dio passes through; the server returns
  HTTP 206 Partial Content with `Content-Range`.
- `onReceiveProgress(int received, int total)`: total is `-1` when
  the server doesn't supply Content-Length (rare for HF). For partial
  content, total is the *remaining* bytes — the downloader adds the
  pre-existing `.partial` size to compute true total.
- `CancelToken.cancel(reason)` aborts the streaming GET; dio raises
  `DioException(type: DioExceptionType.cancel)` which is caught and
  re-emitted as a `DownloadPhase.paused` event by `pause()`.
- `deleteOnError: true` is convenient but not used here — we want to
  preserve `.partial` across pause/resume.

---

## crypto (SHA256 streaming)

`Sha256().convert(bytes)` for small inputs, but the 1 GB weights file
must be hashed in chunks to avoid loading it all into memory. Pattern:

```dart
import 'package:crypto/crypto.dart';
import 'dart:convert';

final output = AccumulatorSink<Digest>();
final input = sha256.startChunkedConversion(output);
await for (final chunk in file.openRead()) {
  input.add(chunk);
}
input.close();
final digestHex = output.events.single.toString();
```

`AccumulatorSink<Digest>` lives in `package:crypto/crypto.dart` (re-
exported by the package; `package:convert` provides the underlying
class but `package:crypto` re-exports it).

`crypto: ^3.0.6` is the active pin.

---

## path_provider

`getApplicationDocumentsDirectory(): Future<Directory>` — Android
returns the app-private docs dir under `/data/data/<pkg>/files/...`.
Survives uninstall = false (expected per slice-8 §10 risk 13). On
Linux the Flutter desktop returns `~/.local/share/<app>/`; we never
exercise this path in production because Cactus is Android-only, but
having `path_provider` work on Linux means Track A's tests can inject
a tmp directory rather than mocking the platform call.

`path_provider: ^2.1.5` is the active pin.

`MissingPlatformDirectoryException` is the documented failure mode;
`ModelPaths` should propagate as `IoException` rather than catching.

---

## Verification (§11) status

- **Item 12 (prompt-parity automated test):** Track A automates this
  in `mobile_backend_test.dart` — asserts `MobileBackend` references
  the slice-6 `kIntentSystem` / `kNarrativeSystem` strings. **Green
  on commit.**
- **Items 1–11 (device-side: download UI, NPU bind, airplane-mode
  generate, memory pressure, idle release, Wi-Fi-only):** **Deferred
  to manual** on the Pixel 9 Pro Fold per slice-8 §1's "Cactus runs
  only on Android arm64". Linux dev environment cannot exercise the
  native binding; tests inject a fake `CactusModelLike` and stop at
  the Dart boundary.

---

## Track B — append below this line

(Track B owns: `apps/mobile/lib/main.dart` platform switch, Settings
download banner, `WidgetsBindingObserver.didHaveMemoryPressure`
bridge, `connectivity_plus` Wi-Fi gate. Track B's doc-refresh
sections — Android memory-pressure / `connectivity_plus` — go here.)

### Android 15 (API 35) — app-private documents directory

WebFetched <https://developer.android.com/about/versions/15/behavior-changes-all>.

- **No new file-size restrictions.** `getApplicationDocumentsDirectory()`
  (which lands under `/data/data/<pkg>/files/…` via path_provider) is
  unchanged on API 35. A 1 GB blob is fine.
- App-private internal storage is still exempt from scoped-storage
  prompts; no UI flow needed for write/delete.
- The Android 15 behaviour-changes page covers private space, 16 KB
  page sizes, OTP redaction, and screenshare protection — none touch
  file size or app-private write paths. Slice 8's footprint
  assumptions hold.

### Android `ComponentCallbacks2` — `onTrimMemory` constants

WebFetched <https://developer.android.com/reference/android/content/ComponentCallbacks2>.

| Constant | Value | When |
|---|---|---|
| `TRIM_MEMORY_RUNNING_MODERATE` | 5 | Foreground app, system is starting to trim background. |
| `TRIM_MEMORY_RUNNING_LOW` | 10 | Foreground app, system is running low on memory. **Slice 8 release pin.** |
| `TRIM_MEMORY_RUNNING_CRITICAL` | 15 | Foreground app, kernel-level memory pressure imminent. |
| `TRIM_MEMORY_UI_HIDDEN` | 20 | UI no longer visible; release UI-related memory. |
| `TRIM_MEMORY_BACKGROUND` | 40 | Process now in background and may be killed soon. |
| `TRIM_MEMORY_MODERATE` | 60 | Background, moderate pressure. |
| `TRIM_MEMORY_COMPLETE` | 80 | Background, severe pressure; LRU killer next. |

Slice 8 §2 (lifecycle bullet) targets `RUNNING_LOW+` (≥ 10) for
release. Flutter surfaces all of these uniformly via
`WidgetsBindingObserver.didHaveMemoryPressure()` — Flutter does NOT
expose the integer level; the framework simply fires the callback
whenever the platform reports pressure. That means our observer
treats every pressure event as "release the model"; finer-grained
gating would require a platform-channel hop, which slice 8 §6's "no
deeper Platform.isAndroid branches" rule disallows. The 5-min idle
releaser handles the soft-pressure case in practice.

### `connectivity_plus` — Wi-Fi-only gate

Resolved Context7 ID `/websites/pub_dev_packages_connectivity_plus`.
Queried `ConnectivityResult mobile wifi onConnectivityChanged stream
checkConnectivity returns List`.

```dart
final List<ConnectivityResult> result =
    await Connectivity().checkConnectivity();
if (result.contains(ConnectivityResult.wifi)) { /* ... */ }

final sub = Connectivity().onConnectivityChanged.listen(
  (List<ConnectivityResult> r) { /* ... */ },
);
```

- Both APIs return `List<ConnectivityResult>` (multi-interface
  awareness — Wi-Fi + Ethernet can coexist on a tablet).
- **Android quirk** (from the package README): when both mobile and
  Wi-Fi are turned on, the system reports **Wi-Fi only**. So our
  gate's check is "Does the list contain `wifi`?" rather than "Does
  the list NOT contain `mobile`?".
- Pin `connectivity_plus: ^6.x`. Latest stable on pub.dev is in the
  `^6.0.x` range as of refresh.

### Riverpod 3.x — `ProviderScope.overrides` for the platform switch

Resolved `/rrousselgit/riverpod`. Queried `ProviderScope overrides
override list FutureProvider override AsyncNotifierProvider Riverpod
3`. Confirmed:

- `provider.overrideWith((ref) => ...)` in the root `ProviderScope`
  works for any provider type (Provider, FutureProvider,
  StreamProvider, AsyncNotifierProvider). The override callback
  receives the same `Ref` type the original provider uses.
- A `FutureProvider<T>.overrideWith((ref) async => ...)` is the
  shape that `llmBackendProvider`'s Android override uses; the
  override body reads `mobileBackendProvider` and returns the
  `MobileBackend`, which implements `LlmBackend` (subtype upcast is
  implicit per Dart variance).
- `overrideWithValue(AsyncValue<T> value)` exists for FutureProvider
  but is intended for tests where you want to pin a specific
  `AsyncValue.data(...)`; we use `overrideWith` because the
  Android-side value is computed lazily from another provider.
- A non-root `ProviderScope` can only override providers that
  declare `dependencies: [...]`; the platform switch lives at the
  root so this restriction does not apply.

### Open question (resolved by Track A's note above)

Track A's HF-pin section flags `qwen3-1.7b-int4.zip` as the
download artifact and asks Track B to decide whether
`ModelDownloader.start()` ends at the .zip on disk or whether
`CactusInit.load` autounzips. **Track B's stance:** the slice plan's
`ModelDownloader` interface (§7) ends at "SHA256-verifies then
renames `.partial → final`"; the unzip lives on Track A's
`CactusInit.load` side. Our UI surfaces "Download complete; first
use will unpack" once `isComplete()` is true. If Track A defers the
unzip into `MobileBackend.buildIntent`, the Settings → LLM "Ready"
row still renders correctly because `isModelLoaded` only flips true
after the first successful chat; Track B's UI keys off
`isComplete()` for the banner switch, not `isModelLoaded`. This is
documented in `model_download_card.dart`'s "done" state comment.
