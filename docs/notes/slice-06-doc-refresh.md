# Slice 6 — doc-refresh notes (per §4)

## Track A scope (pure-Dart engine, this file)

Track A's surface is HTTP-free; all that matters here is that the
`LlmBackend` interface holds the right shape for what an Ollama or
Cactus backend can reasonably emit. No `dio` lives in
`packages/playlist_engine`; Track B owns the wire.

### Qwen3 chat template + reserved tokens (focus: `<think>` stripping)

- `Qwen/Qwen3-1.7B` (HuggingFace model card; cached recall) —
  applies a `chatml`-style template inside Ollama. Reserved tokens:
  `<|im_start|>`, `<|im_end|>`, plus optional reasoning markers
  `<think>`…`</think>` when the model auto-enables thinking. JSON-
  mode emissions sometimes lead with `<think>…</think>` before the
  payload, so `json_repair.dart` (Track B) strips a leading
  `<think>...</think>` block. Dangling `<think>` with no closer is
  treated as malformed → engine repair loop fires.
- Whitespace-sensitive: trim and remove ```` ``` ```` code-fence
  wrappers before `jsonDecode`. Track A's `Intent.fromJson` assumes
  the caller has already done that — it operates on a parsed `Map`,
  not a raw string.

### Ollama API surface (Track A only needs the request shape)

- `POST /api/chat` body:
  ```json
  {
    "model": "qwen3:1.7b",
    "messages": [{"role":"system","content":"..."},
                 {"role":"user","content":"..."}],
    "stream": true,
    "format": <JSON Schema object> | "json",
    "keep_alive": "10m",
    "options": {"temperature": 0.1, "num_ctx": 4096, "seed": -1}
  }
  ```
- Streaming = `application/x-ndjson`; one object per line with
  `response`, `done`, `eval_count`. Track A's `LlmProgress` carries
  `tokenChunk` per chunk.
- `format: <schema>` is newer (rolling release). On 400, Track B
  falls back to `format: "json"`. Track A doesn't care which —
  `LlmJsonParseException` covers both modes uniformly.
- `keep_alive: "10m"` pins the model between `buildIntent` and
  `refine` (≈2 s apart). Slower-than-5 s first narrative chunk =
  warning per §10 risk 8.

### Spec deviation (CRITICAL — Track A's commitment to B + C)

Plan §7 sketches `LlmBackend.refine(Intent, List<Track>)` and
`TrackRepo.trackOf(int) → Track`. `Track` lives in `prism_core` and
`packages/playlist_engine` cannot import it (slice-5 §6 hard rule).
Resolution applied on Track A:

- `LlmBackend.refine(Intent, List<CandidateMeta>) → Future<FinalPass>`.
  Slice-5's `CandidateMeta` already carries `trackId, artistKey,
  title, key, year, bpm` plus mood scalars — exactly what
  `kNarrativeSystem` serializes (`id | title | artist | bpm | key |
  year`).
- `PlaylistResult.trackIds: List<int>` (length == 12). Adapters /
  UI materialise int → Track via slice-5's existing
  `trackByIdLookupProvider` in apps/mobile.
- `PlaylistResult.candidates: List<CandidateMeta>` (same length,
  same order) so the result card can render rows without an extra
  repo round-trip.
- `TrackRepo` does **not** add `trackOf`. `metaOf(int) →
  CandidateMeta` already inherited from `PlaylistRepo` is enough
  for the engine.
- Documented in `llm_backend.dart` and `playlist_result.dart`
  module docstrings.

## (Tracks B + C append below — leave this fence intact)

## Track B scope (`packages/llm_desktop` — Ollama REST + JSON repair)

Wire-level concerns Track A does not see. Every doc was checked
before any Dart was touched in `packages/llm_desktop/`.

### Ollama REST API — `/api/generate`, `/api/chat`, `/api/tags`, `/api/pull`

- `WebFetch https://github.com/ollama/ollama/blob/main/docs/api.md`
  (refreshed before coding):
  - `format` accepts BOTH `"json"` (string) and a JSON Schema
    object (literal `{"type":"object","properties":...}`) — the
    docs say "Format can be `json` or a JSON schema". Newer builds
    on the rolling release accept the schema object; older / pinned
    builds 400 on a non-string `format`. Track B's `OllamaBackend`
    sends the schema object first, falls back to `"json"` on a 400
    response.
  - Streaming response is one JSON object per line (newline-
    delimited). The docs do not pin the `Content-Type` to
    `application/x-ndjson` exclusively — some builds emit
    `application/json` with a `\n`-delimited body. Track B does NOT
    rely on the header; `NdjsonDecoder` consumes raw `Stream<Uint8List>`
    via `utf8.decoder` + `LineSplitter` regardless of the declared
    MIME type.
  - `/api/chat` chunk shape: `{message: {role, content}, done,
    eval_count, ...}`. `/api/generate` chunk shape:
    `{response: "...", done, eval_count, ...}`. The backend reads
    `chunk['message']['content']` first, falls back to
    `chunk['response']`.
  - `keep_alive`: docs example uses `"5m"` (string with unit) as
    default. Integer `0` documented for unload. Track B's
    `_formatKeepAlive(Duration d)` emits `"${d.inSeconds}s"` —
    string-with-unit form, accepted by every Ollama version since
    `keep_alive` was added. Avoiding the `"10m"` form prevents
    surprise rounding when callers pass `Duration(seconds: 90)`.
  - `/api/tags` response: `{"models":[{"name":"qwen3:1.7b",
    "model":"qwen3:1.7b", ...}, ...]}`. `name` and `model` carry
    the same value; Track B reads `name` and falls back to `model`
    when `name` is absent (defensive across builds).
  - `/api/pull` progress: `{"status":"pulling digestname","digest":
    "...", "total":<bytes>, "completed":<bytes>}`. `completed` may
    be omitted before the first byte. Track B's `pull` callback
    emits `completed/total` when both are present, else 0.

### Qwen3-1.7B reasoning tokens (focus: `<think>` strip)

- `WebFetch https://huggingface.co/Qwen/Qwen3-1.7B`: when
  `enable_thinking=True` (the default in Ollama's Modelfile for
  `qwen3:*`) the model emits `<think>...</think>` BEFORE the
  answer, even in JSON mode. The closing tag has reserved token id
  `151668` but the text representation is the literal string
  `</think>`. Track B's `JsonRepair.repairForJson` strips a
  leading `<think>` block (greedy across newlines) before any
  fence stripping or trim. Dangling `<think>` (no closer) is left
  alone — caller's `jsonDecode` will throw and the repair loop on
  the engine side picks it up.

### `dio` 5.x — streaming, cancel, BaseOptions, MockAdapter

- `mcp__plugin_context7_context7__resolve-library-id` →
  `/cfug/dio` + `query-docs topic: "ResponseType.stream
  CancelToken receiveTimeout BaseOptions"`:
  - `Options(responseType: ResponseType.stream)` makes `res.data`
    a `ResponseBody` whose `.stream` is `Stream<Uint8List>`. Track
    B casts to `Stream<Uint8List>` and pipes through
    `NdjsonDecoder`.
  - `CancelToken.cancel('reason')` rejects the in-flight request
    with `DioException(type: DioExceptionType.cancel)`.
    `CancelToken.isCancel(e)` is the canonical check; Track B uses
    it inside `OllamaBackend.buildIntent` / `refine` to convert to
    `PlaylistCancelled`.
  - dio 5.0+ takes timeouts as `Duration` objects, not int ms. We
    use `connectTimeout: 5s`, `receiveTimeout: Duration.zero` for
    streaming endpoints (model-load on a cold daemon can take
    30+ s; receiveTimeout would falsely abort).
- MockAdapter pattern: slice-2 uses a hand-rolled `_StubAdapter
  implements HttpClientAdapter` (see
  `packages/metadata/test/mb_client_fake_test.dart`). Track B
  mirrors that — no `package:http_mock_adapter` dependency.
  `ResponseBody` has two factories: `fromString` (for
  buffered responses, used by `tags` test) and `fromStream` (for
  ndjson streaming tests, lets us emit chunked `Uint8List`s with
  realistic mid-line splits to verify
  `LineSplitter` accumulates correctly across chunks).
<!-- track-c-append -->
## Track C scope (`packages/core` SQLite adapter + `apps/mobile` UI)

Track C bridges the engine to `CacheDb` and ships every Flutter
surface that consumes it. No HTTP, no LLM transport — both Track A
(engine) and Track B (Ollama wire) are pure-Dart upstream. Doc-refresh
focus: Riverpod 3.x AsyncNotifier semantics + SharedPreferences for
the persisted Ollama URL.

### `flutter_riverpod` 3.x — AsyncNotifier.family + invalidate + valueOrNull

- `mcp__plugin_context7_context7__resolve-library-id libraryName:
  "flutter_riverpod"` → `/rrousselgit/riverpod` + `query-docs topic:
  "AsyncNotifierProvider family stream state invalidate"`:
  - `AsyncNotifierProvider.family<NotifierT, T, ArgT>(NotifierT.new)`
    builds a notifier per `arg` value; identity is `==` on the arg.
    Two `newVibeProvider('rainy')` reads share the same notifier
    instance; `newVibeProvider('happy')` is a separate one.
  - The notifier subclass is `FamilyAsyncNotifier<T, ArgT>` (singular
    `arg`, not a tuple). Inside `build()` the `arg` field is the
    family parameter; mutations call `state = AsyncData(...)` /
    `AsyncError(...)` / `AsyncLoading()`.
  - `ref.invalidate(provider)` (or `ref.invalidate(family(arg))`)
    discards the cached notifier + state and re-runs `build()` on
    next watch. Used for "Generate again".
  - **Riverpod 3 dropped `AsyncValue.valueOrNull`.** Replacement is
    `asData?.value` (returns `T?`). Track C's UI uses this everywhere
    so a partial AsyncLoading state doesn't trip a null deref.
  - `Notifier<T>` (non-async) for `OllamaConfig` — synchronous get/set
    over the prefs-backed value; no AsyncValue needed because the
    initial load fires once in `build()` and the rest is in-memory.
  - `StreamProvider<T>` polling pattern: an `async*` body that
    `yield`s once eagerly, then `await Future.delayed`s + `yield`s in
    a loop. Listener teardown stops the loop via `ref.onDispose` or
    by `await`ing on the disposed ref (the StreamProvider bridge
    handles cancellation when no listeners remain — Riverpod's docs
    confirm: "the stream is cancelled when no longer listened to").

### `shared_preferences` — getString / setString

- `mcp__plugin_context7_context7__resolve-library-id libraryName:
  "shared_preferences"` → `/flutter/plugins` + `query-docs topic:
  "getString setString"`:
  - `SharedPreferences.getInstance() → Future<SharedPreferences>` —
    cached singleton on first call, sync from then on.
  - `prefs.getString(key) → String?` — null when missing. Track C's
    `OllamaConfigNotifier` uses this for `prism.llm.ollama_url` and
    falls through to the `OllamaConfig()` default.
  - `prefs.setString(key, value) → Future<bool>` — fire-and-forget on
    success; the in-memory state is the source of truth between
    persists.

### Track B contract drift (as of Track C kickoff)

Track B has shipped `OllamaConfig` only. `OllamaClient`,
`OllamaBackend`, `OllamaHealth`, `OllamaHealthStatus`, and the
`prism_llm_desktop` barrel are not yet present. Track C imports them
via `package:prism_llm_desktop/llm_desktop.dart` per the brief and
flags every consumer with `TODO(slice-6-integration)` comments. The
notifier layer is shaped against the documented signatures so
hooking up the real symbols is purely a name-resolution pass.

### Track A contract drift (as of Track C kickoff)

Track A's `playlist_engine.dart` barrel does **not** yet export
`intent.dart`, `final_pass.dart`, `playlist_result.dart`, or
`llm_backend.dart`. Track C imports those modules via deeper
`package:prism_playlist_engine/<file>.dart` paths and leaves a
`TODO(slice-6-integration)` next to each so the user can tighten
once Track A appends the exports. `Intent`, `FinalPass`,
`PlaylistResult`, `PlaylistDebug`, `EnergyArc`, `LlmBackend`,
`LlmProgress`, `PlaylistStep`, `LlmJsonParseException`,
`PlaylistCancelled`, `RelaxationLevel`, `MoodLookup`, and the new
`TrackRepo` all resolve via those deeper paths today — the barrel
clean-up is a one-line append per file.

The `PlaylistEngine` class itself is **not yet defined** in Track A.
`apps/mobile/lib/providers/playlist_engine_providers.dart` builds
its `Provider<PlaylistEngine>` against the documented constructor
(`const PlaylistEngine()`) and `generate({...}) → Future<PlaylistResult>`
signature; the marker `TODO(slice-6-integration)` flags the call
site so it's grep-able when Track A lands the class.
