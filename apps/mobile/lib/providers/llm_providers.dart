/// Riverpod wiring for slice 6's Ollama backend.
///
/// Public surface:
///
/// - [ollamaConfigProvider] — `NotifierProvider<OllamaConfigNotifier,
///   OllamaConfig>`. Loads the persisted base URL from
///   SharedPreferences (`prism.llm.ollama_url`) on first build;
///   `setUrl(String)` persists + republishes.
/// - [ollamaClientProvider] — derived `OllamaClient` over a single
///   `Dio` instance whose options track the active config.
/// - [ollamaBackendProvider] — derived `OllamaBackend` (implements
///   `LlmBackend` from `prism_playlist_engine`); the slice-6 backend
///   instance, also surfaced via [llmBackendProvider] on non-Android
///   platforms.
/// - [ollamaHealthProvider] — `StreamProvider<OllamaHealth>` that
///   polls every 30 s while a listener is active. Settings → LLM
///   binds the dot color to the latest `status`.
/// - [llmBackendProvider] — slice-8 platform seam.
///   `FutureProvider<LlmBackend>` that defaults to the Ollama backend
///   above; `apps/mobile/lib/main.dart` overrides this in the root
///   `ProviderScope` on Android to wrap the Cactus-backed
///   `MobileBackend` from `llm_providers_mobile.dart`. Slice 6
///   originally exposed `ollamaBackendProvider` directly to consumers;
///   slice 8 routes them through this typed seam so the engine is
///   platform-agnostic at the call site.
///
/// Cancellation contract (slice 6, unchanged for Linux desktop):
/// closing the New Vibe sheet calls
/// `ref.read(ollamaBackendProvider).cancel()`. The backend cancels
/// the active `dio` request via its `CancelToken`; in-flight
/// `generate()` futures throw `PlaylistCancelled`, which the notifier
/// translates to `state = AsyncData(state.copyWith(cancelled: true))`.
/// On Android the cancel call still routes through this provider
/// (the slice-8 brief asks for a single-seam reroute through
/// [llmBackendProvider] but `LlmBackend` doesn't expose `cancel()` —
/// see the long comment on [llmBackendProvider] below). The
/// Android-side Cactus cancellation lives inside `MobileBackend`'s
/// own onToken callback (Track A's doc-refresh §10 risk 6).
///
/// **Track B integration drift (as of Track C kickoff)**:
/// `prism_llm_desktop` ships only `OllamaConfig`. `OllamaClient`,
/// `OllamaBackend`, `OllamaHealth`, and `OllamaHealthStatus` are
/// imported via `package:prism_llm_desktop/llm_desktop.dart` per the
/// brief and flagged with `TODO(slice-6-integration)`. The notifier
/// shape is fixed against the documented signatures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// TODO(slice-6-integration): tighten to just
// `package:prism_llm_desktop/llm_desktop.dart` once Track B exports
// the barrel. Today the package only ships OllamaConfig — the rest
// of these symbols (OllamaClient, OllamaBackend, OllamaHealth,
// OllamaHealthStatus) are referenced against their documented names
// per slice 6 §7. Compilation will fail until Track B lands them;
// the user reconciles at integration time.
import 'package:prism_llm_desktop/llm_desktop.dart';
import 'package:prism_playlist_engine/llm_backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the persisted Ollama base URL.
const String kOllamaUrlPrefsKey = 'prism.llm.ollama_url';

/// Process-singleton config — Riverpod-owned so the URL change in
/// Settings instantly republishes both client + backend providers.
final ollamaConfigProvider =
    NotifierProvider<OllamaConfigNotifier, OllamaConfig>(
  OllamaConfigNotifier.new,
);

class OllamaConfigNotifier extends Notifier<OllamaConfig> {
  @override
  OllamaConfig build() {
    // Kick off the persisted-URL hydration off the build() call so
    // a missing prefs binding doesn't block app boot. Same pattern
    // as `RecentSeedsNotifier` (slice 5).
    // ignore: discarded_futures
    _hydrate();
    // OllamaConfig's ctor is non-const (Uri.parse can't be const),
    // so the default fallback is built once per Riverpod
    // container rebuild — cheap.
    return OllamaConfig();
  }

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kOllamaUrlPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final uri = Uri.parse(raw);
      state = state.copyWith(baseUrl: uri);
    } catch (_) {
      // Bad persisted value — fall back to the default and
      // overwrite the prefs so we don't keep retrying.
      await prefs.setString(kOllamaUrlPrefsKey, state.baseUrl.toString());
    }
  }

  /// Persists [url] and republishes [state] with the new base URL.
  /// Invalid URIs are rejected silently — Settings disables the
  /// commit button when the field's text doesn't parse.
  Future<void> setUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    final Uri parsed;
    try {
      parsed = Uri.parse(trimmed);
    } catch (_) {
      return;
    }
    state = state.copyWith(baseUrl: parsed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kOllamaUrlPrefsKey, parsed.toString());
  }

  /// Replaces the model tag (advanced setting; not surfaced in
  /// slice 6's UI but kept here for slice-7 polish + tests).
  Future<void> setModel(String model) async {
    state = state.copyWith(model: model);
  }
}

/// Long-lived `Dio` instance — one per container so connection
/// pooling persists across health pings + the two LLM passes.
/// Options track the active [OllamaConfig] via `ref.watch`, so a URL
/// change in Settings re-binds the next backend call without a
/// container reset.
final ollamaClientProvider = Provider<OllamaClient>((ref) {
  // Track B's `OllamaClient` constructor ended up with both args
  // named: `OllamaClient({required OllamaConfig config, Dio? dio})`.
  // Slice plan §7 sketched a positional `Dio`; the implementation
  // diverged so the optional Dio has a sensible default.
  final cfg = ref.watch(ollamaConfigProvider);
  return OllamaClient(config: cfg);
});

/// `OllamaBackend` — implements `LlmBackend` from playlist_engine.
/// This is the value `playlistEngineProvider`'s `generate()`
/// consumes. The instance is rebuilt whenever the config changes so
/// the next pass picks up the new URL.
final ollamaBackendProvider = Provider<OllamaBackend>((ref) {
  // TODO(slice-6-integration): OllamaBackend ctor signature per
  // slice plan §7: `OllamaBackend(OllamaClient client,
  // {required OllamaConfig config})`. Track B has not yet shipped
  // this class.
  final client = ref.watch(ollamaClientProvider);
  final cfg = ref.watch(ollamaConfigProvider);
  return OllamaBackend(client, config: cfg);
});

/// Health stream — eagerly emits the current state, then re-polls
/// every 30 s while a listener is active. The Riverpod stream
/// bridge cancels the loop when the last listener leaves; we also
/// guard re-entry against `ref.onDispose` flips during a pending
/// `health()` call.
final ollamaHealthProvider = StreamProvider<OllamaHealth>((ref) async* {
  // TODO(slice-6-integration): OllamaHealth + OllamaHealthStatus
  // values per slice plan §7. Backend.health() returns
  // `Future<OllamaHealth>` per the brief.
  final backend = ref.watch(ollamaBackendProvider);
  yield await backend.health();
  while (true) {
    await Future<void>.delayed(const Duration(seconds: 30));
    // Re-read in case the URL changed in Settings while the loop
    // was sleeping; ref.watch above only fires on the very first
    // yield, so the read here keeps the polling cadence honest
    // against config drift.
    final current = ref.read(ollamaBackendProvider);
    yield await current.health();
  }
});

/// Slice 8 platform seam. The single `LlmBackend` consumed by
/// `playlistEngineProvider`'s `generate(...)` call. Defaults to the
/// slice-6 [ollamaBackendProvider]; `apps/mobile/lib/main.dart`
/// overrides this on Android in the root `ProviderScope` to return
/// slice-8's Cactus-backed `MobileBackend` from
/// `llm_providers_mobile.dart`.
///
/// **Why a `FutureProvider` rather than a plain `Provider`?** The
/// Cactus backend needs to resolve `path_provider`'s
/// `getApplicationDocumentsDirectory()` (an async platform-channel
/// call) before it can be constructed; a `Provider<LlmBackend>` would
/// force `MobileBackend` to defer its init internally and complicate
/// the cancellation contract. The default Ollama path resolves
/// synchronously and re-emits the singleton; the await is a no-op
/// on Linux.
///
/// **Cancellation seam**: `LlmBackend` doesn't expose `cancel()` —
/// the desktop slice-6 cancel path is `OllamaBackend`-specific and
/// the mobile cancel path lives inside `MobileBackend`'s `onToken`
/// callback (per Track A's doc-refresh §10 risk 6). The slice-8
/// brief asks for "audit every reference and reroute through
/// `llmBackendProvider`"; we honour that for the *consumer-side*
/// `generate(...)` call. The cancel sites in
/// `playlist_engine_providers.dart` and `screens/new_vibe.dart`
/// continue to read `ollamaBackendProvider` directly because the
/// `cancel()` symbol is slice-6-specific. On Android, calling
/// `ollamaBackendProvider.cancel()` against an unused backend is
/// idempotent and inert — no in-flight Dio request exists to
/// cancel, and the Cactus side's cancellation runs through a
/// different path (`PlaylistCancelled` thrown from inside
/// `onToken`).
final llmBackendProvider = FutureProvider<LlmBackend>((ref) async {
  return ref.watch(ollamaBackendProvider);
});
