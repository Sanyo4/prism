/// Riverpod wiring for slice 8's Cactus-backed `MobileBackend`.
///
/// **Android-only.** `apps/mobile/lib/main.dart` applies a single
/// `ProviderScope` override on `Platform.isAndroid` that swaps
/// `llmBackendProvider` to read [mobileBackendProvider]; on Linux
/// desktop the slice-6 `OllamaBackend` (in `llm_providers.dart`)
/// stays the active backend. This file contains zero
/// `Platform.isAndroid` branches — the override is the entire seam
/// (slice 8 §6 hard rule).
///
/// Public surface:
///
/// - [cactusModelSpecProvider] — `Provider<CactusModelSpec>` returning
///   the slice-8 pinned `kQwen3_1_7B_INT4` constant; Settings UI reads
///   `spec.sizeBytes` and `spec.sha256Hex` for the download card.
/// - [modelPathsProvider] — `FutureProvider<ModelPaths>` resolved off
///   `path_provider.getApplicationDocumentsDirectory()` so the
///   downloader and Cactus init share a single source-of-truth path.
/// - [modelDownloaderProvider] — `FutureProvider<ModelDownloader>`
///   composed over a long-lived `Dio` instance.
/// - [modelDownloadStateProvider] — `StreamProvider<DownloadProgress>`
///   that re-yields the downloader's `progress` stream so the
///   `ModelDownloadCard` can `ref.watch` it directly.
/// - [cactusInitProvider] — `FutureProvider<CactusInit>` configured
///   with the spec, paths, and the NPU probe.
/// - [idleReleaserProvider] — `Provider<IdleReleaser>` (5-minute
///   timer); disposed when its container shuts down.
/// - [mobileBackendProvider] — `FutureProvider<MobileBackend>` —
///   wires init + idle releaser + memory-pressure listener. The
///   subtype-upcast to `LlmBackend` happens inside `main.dart`'s
///   override.
/// - [wifiOnlyDownloadProvider] — `NotifierProvider<bool>` persisted
///   via SharedPreferences key `prism.llm.wifi_only`. Default `true`
///   per slice 8 §10 risk 1.
/// - [connectivityProvider] — `StreamProvider<ConnectivityResult>`
///   that derives a single "best" interface from
///   `connectivity_plus`'s multi-interface list.
/// - [memoryPressureNotifierProvider] — `NotifierProvider<int>`
///   incremented by [MemoryPressureObserver]; `mobileBackendProvider`
///   listens and fires `releaseModel()` on every flip.
///
/// **Track A integration drift (as of slice 8 Track B kickoff):**
/// `package:prism_llm_mobile/llm_mobile.dart` (the barrel) does not
/// yet exist — Track A has only published `pubspec.yaml`. Every
/// import below is flagged with `TODO(slice-8-integration)` against
/// the documented symbol names from slice 8 §7. Compilation will
/// fail until Track A lands them; the user reconciles at integration
/// time.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
// TODO(slice-8-integration): tighten to just
// `package:prism_llm_mobile/llm_mobile.dart` once Track A exports
// the barrel. As of Track B kickoff Track A has only shipped the
// package's pubspec.yaml — every symbol below (CactusModelSpec,
// ModelPaths, ModelDownloader, DownloadProgress, DownloadPhase,
// CactusInit, NpuProbe, NpuSupport, IdleReleaser, MobileBackend,
// kQwen3_1_7B_INT4, ModelMissing, CactusInitFailed) is referenced
// against the names in `docs/plans/slice-08-android-cactus-llm.md`
// §7. Compilation will fail until the barrel ships.
import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the "Wi-Fi only" download toggle.
const String kWifiOnlyDownloadPrefsKey = 'prism.llm.wifi_only';

/// Pinned Cactus model spec — slice 8 §7 / §4. Track A populates
/// `kQwen3_1_7B_INT4` from the HF revision SHA pin in their doc-
/// refresh notes. If the SHA256 string is empty (`''`), the
/// `ModelDownloadCard` refuses to start and surfaces the "Pin
/// missing" hint per slice 8 §10 risk 8.
final cactusModelSpecProvider = Provider<CactusModelSpec>(
  (ref) => kQwen3_1_7B_INT4,
);

/// Resolves the app-private docs directory once and threads it
/// through both the downloader and the Cactus init. Survives
/// uninstall = false per slice 8 §10 risk 13.
///
/// Note: Track A's `ModelPaths` shipped with named-arg constructor
/// `ModelPaths({required rootDirProvider, required spec})` rather
/// than the positional `ModelPaths(spec, dir)` the slice-plan §7
/// sketch implied. The `rootDirProvider` field is a
/// `Future<Directory> Function()` so tests can inject a tmp dir.
/// We pass `getApplicationDocumentsDirectory` directly (a Future-
/// returning function reference); the provider awaits it lazily.
final modelPathsProvider = Provider<ModelPaths>((ref) {
  final spec = ref.watch(cactusModelSpecProvider);
  return ModelPaths(
    rootDirProvider: getApplicationDocumentsDirectory,
    spec: spec,
  );
});

/// Long-lived `Dio` for the download. We deliberately do NOT share
/// this instance with the slice-6 `ollamaClientProvider` because the
/// HF download and the Ollama health pings have different timeout
/// + redirect requirements; isolating them keeps the connection pool
/// small and avoids cross-contamination of `Dio.options.headers`.
final _modelDownloadDioProvider = Provider<Dio>((ref) {
  final dio = Dio();
  ref.onDispose(dio.close);
  return dio;
});

/// `ModelDownloader` over `Dio` — pause/resume/SHA256-verify per
/// slice 8 §7. Re-emitted whenever the spec or paths change (which,
/// in production, is once per app process — these inputs are
/// effectively constants).
final modelDownloaderProvider = Provider<ModelDownloader>((ref) {
  final dio = ref.watch(_modelDownloadDioProvider);
  final spec = ref.watch(cactusModelSpecProvider);
  final paths = ref.watch(modelPathsProvider);
  // Track A's `ModelDownloader(this._dio, this.spec, this.paths,
  // {this.diskHeadroomBytes})` — positional with optional named.
  return ModelDownloader(dio, spec, paths);
});

/// Re-broadcast the downloader's progress as a Riverpod stream so the
/// `ModelDownloadCard` can `ref.watch(modelDownloadStateProvider)`
/// without holding a `StreamSubscription` itself.
final modelDownloadStateProvider =
    StreamProvider<DownloadProgress>((ref) async* {
  final downloader = ref.watch(modelDownloaderProvider);
  yield* downloader.progress;
});

/// `CactusInit` — handles the NPU-aware load (slice 8 §7). Track A's
/// doc-refresh note clarifies that v1.3.0 does not surface a runtime
/// `backend: cpu|npu` selector, so `load(NpuSupport)` is a probe-
/// driven path; the parameter still threads through the init for
/// diagnostic reporting.
///
/// Track A's ctor: `CactusInit({required spec, required paths,
/// required probe, nativeInit})` — named args with a test-only
/// `nativeInit` seam.
final cactusInitProvider = Provider<CactusInit>((ref) {
  final spec = ref.watch(cactusModelSpecProvider);
  final paths = ref.watch(modelPathsProvider);
  return CactusInit(spec: spec, paths: paths, probe: NpuProbe());
});

/// 5-minute idle releaser; disposed when the provider container
/// shuts down so the timer doesn't outlive the app process.
final idleReleaserProvider = Provider<IdleReleaser>((ref) {
  final releaser = IdleReleaser();
  ref.onDispose(releaser.dispose);
  return releaser;
});

/// Riverpod-owned `MobileBackend`. The platform switch in
/// `main.dart` overrides `llmBackendProvider` to read this provider's
/// future and upcast to `LlmBackend`; on Linux the override is not
/// applied, so `mobileBackendProvider` is never built.
///
/// This provider also wires the two release-on-event paths:
///
///   1. `idle.shouldRelease` — slice 8 §7 / §10 risk 12. Touched on
///      every `chat()`; emits after 5 min of true silence.
///   2. `memoryPressureNotifierProvider` — slice 8 §10 risk 6. The
///      [MemoryPressureObserver] (registered in `main.dart`) fires
///      this on every `didHaveMemoryPressure` callback; the listener
///      below calls `releaseModel()` once per increment.
final mobileBackendProvider = Provider<MobileBackend>((ref) {
  final init = ref.watch(cactusInitProvider);
  final idle = ref.watch(idleReleaserProvider);
  final spec = ref.watch(cactusModelSpecProvider);
  // Track A's ctor: `MobileBackend({required init, required idle,
  // CactusModelSpec? spec})`. Spec defaults to kQwen3_1_7B_INT4 if
  // omitted; we pass the provider value through explicitly so tests
  // can override the spec via `cactusModelSpecProvider`.
  final backend = MobileBackend(init: init, idle: idle, spec: spec);

  // (1) Idle-release subscription. The releaser emits on its own
  // timer; we listen via a stream subscription so cancellation lives
  // alongside the provider's `onDispose`. `ref.listen` would only
  // work if `idle.shouldRelease` were itself a provider.
  final idleSub = idle.shouldRelease.listen((_) {
    // ignore: discarded_futures
    backend.releaseModel();
  });
  ref.onDispose(idleSub.cancel);

  // (2) Memory-pressure listener. The notifier is incremented by
  // `MemoryPressureObserver` in `main.dart`; every flip triggers a
  // release. The listener is keyed off identity (state == previous
  // never holds because we increment), so we don't need to dedupe.
  ref.listen<int>(memoryPressureNotifierProvider, (prev, next) {
    if (prev == next) return; // defensive — Notifier shouldn't re-emit equal
    // ignore: discarded_futures
    backend.releaseModel();
  });

  // Tear down the backend when the container disposes — releases the
  // resident model handle (via Cactus FFI) without leaking native
  // memory across hot-restart in dev.
  ref.onDispose(() {
    // ignore: discarded_futures
    backend.releaseModel();
  });

  return backend;
});

/// "Wi-Fi only" download toggle. Default `true` per slice 8 §10 risk
/// 1. Persisted via `SharedPreferences` so the choice survives app
/// restart.
final wifiOnlyDownloadProvider =
    NotifierProvider<WifiOnlyDownloadNotifier, bool>(
  WifiOnlyDownloadNotifier.new,
);

class WifiOnlyDownloadNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Hydrate off-build so a missing prefs binding doesn't deadlock
    // initial render. Same pattern as
    // `OllamaConfigNotifier._hydrate` (slice 6 wiring).
    // ignore: discarded_futures
    _hydrate();
    return true;
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getBool(kWifiOnlyDownloadPrefsKey);
    if (raw == null) {
      // First launch — persist the default so subsequent reads are
      // explicit. Avoids a "never been set" → "user disabled it"
      // ambiguity if we later ship migration logic.
      await prefs.setBool(kWifiOnlyDownloadPrefsKey, true);
      return;
    }
    if (raw == state) return;
    state = raw;
  }

  /// Persists [enabled] and republishes [state]. The
  /// `ModelDownloadCard` reads this for its gate; the Settings switch
  /// drives the value.
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kWifiOnlyDownloadPrefsKey, enabled);
  }
}

/// Reduces `connectivity_plus`'s multi-interface list to a single
/// "best" `ConnectivityResult` so the download card's gate is a flat
/// equality check. Priority: `wifi > ethernet > mobile > vpn > other
/// > none`. Wi-Fi short-circuits because the slice-8 §11 item 8
/// pass criterion is "switching to Wi-Fi auto-resumes" — that
/// transition needs to be visible here even when mobile is also
/// reachable.
///
/// **Android note** (from `connectivity_plus` README): the platform
/// reports Wi-Fi only when both Wi-Fi and mobile are active, so the
/// fold-down is a no-op on most Android phones; we still keep the
/// reduction logic for tablets / desktops where multi-interface is
/// real.
final connectivityProvider = StreamProvider<ConnectivityResult>((ref) async* {
  final connectivity = Connectivity();
  // First, push the current snapshot so consumers don't sit on a
  // loading state while the platform's broadcast warms up.
  try {
    final initial = await connectivity.checkConnectivity();
    yield _foldConnectivity(initial);
  } catch (_) {
    // Platform exception (rare; happens on Linux desktop where the
    // method channel may not be wired). Surface "none" rather than
    // throwing — the download gate degrades gracefully to "no
    // connection".
    yield ConnectivityResult.none;
  }
  await for (final list in connectivity.onConnectivityChanged) {
    yield _foldConnectivity(list);
  }
});

ConnectivityResult _foldConnectivity(List<ConnectivityResult> list) {
  if (list.isEmpty) return ConnectivityResult.none;
  if (list.contains(ConnectivityResult.wifi)) return ConnectivityResult.wifi;
  if (list.contains(ConnectivityResult.ethernet)) {
    return ConnectivityResult.ethernet;
  }
  if (list.contains(ConnectivityResult.mobile)) {
    return ConnectivityResult.mobile;
  }
  if (list.contains(ConnectivityResult.vpn)) return ConnectivityResult.vpn;
  if (list.contains(ConnectivityResult.bluetooth)) {
    return ConnectivityResult.bluetooth;
  }
  if (list.contains(ConnectivityResult.other)) return ConnectivityResult.other;
  return ConnectivityResult.none;
}

/// Bridge for `MemoryPressureObserver` → `mobileBackendProvider`
/// release. The observer increments [state] on every
/// `didHaveMemoryPressure`; the backend listens and triggers
/// `releaseModel()`. We use a counter (rather than a `void` stream)
/// because `Notifier`'s state is comparison-based; a counter forces
/// each event to register as a state change.
final memoryPressureNotifierProvider =
    NotifierProvider<MemoryPressureNotifier, int>(MemoryPressureNotifier.new);

class MemoryPressureNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Increments the counter. Consumers `ref.listen` for the change
  /// and fire their release work.
  void fire() => state = state + 1;
}

