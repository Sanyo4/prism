# Slice 6 — Desktop LLM Playlists (Ollama + Qwen3-1.7B, 12-track `PlaylistEngine`)

## 1. Context

Slice 6 is the LLM counterpart to slice 5. Where slice 5 ships an
infinite, deterministic radio driven purely by `vec0` kNN + chips,
slice 6 ships a **one-shot, natural-language, 12-track playlist**
backed by a local LLM. Both paths share the same engine primitives —
`FlowScorer`, `Camelot`, and the `PlaylistRepo` port from
`packages/playlist_engine`. The LLM does not rank, seek, or beatmatch;
it translates human intent into a structured query, then applies
narrative judgement over a flow-scored candidate list. Deterministic
pipes in the middle; probabilistic pipes at the ends.

This slice is **desktop-only**. It introduces `packages/llm_desktop`
(a thin Ollama REST client) and `class PlaylistEngine` in
`packages/playlist_engine` beside `RadioEngine`. It also introduces
the `LlmBackend` abstract class that **slice 8 will re-implement on
Android via Cactus**. The interface is deliberately small:
`buildIntent` and `refine`. Anything more (streaming, model metadata,
health probes) lives on the backend-local adapter, not the shared
contract — that keeps slice 8's Cactus integration a provider swap
and keeps engine tests isolate-pure against an in-memory mock.

The model is **Qwen3-1.7B-Instruct** via Ollama tag `qwen3:1.7b` on
Linux; slice 8's Android twin uses Cactus with a Qwen3-1.7B INT4
weight. Cactus does not support Qwen2.5 so the choice is locked.
Playlist length is **12** per `docs/plans/README.md` invariants, not
the 15 in the original spec draft. Slices 1, 3, 4, 5 are assumed done.

## 2. Goals / Non-goals

**Goals**

- `packages/llm_desktop` — pure Dart, deps `dio` + path to
  `packages/playlist_engine`. Exposes `OllamaBackend implements
  LlmBackend`, an `OllamaClient` covering `/api/generate`,
  `/api/chat`, `/api/tags`, `/api/pull`, plus `OllamaHealth`.
- Extend `packages/playlist_engine` with: `abstract class LlmBackend`
  (two methods + progress stream); `class PlaylistEngine` running the
  6-step pipeline (§5); `Intent`, `FinalPass`, `PlaylistResult` value
  types; `lib/prompts/intent_prompt.dart` (temp 0.1, strict JSON
  schema); `lib/prompts/narrative_prompt.dart` (temp 0.7, ≤ 4 swaps,
  blurb ≤ 2 sentences).
- Engine is a pure function on `(vibe, LlmBackend, TrackRepo) →
  PlaylistResult`. Identical call site on desktop and (slice 8)
  Android; only the backend differs.
- UI: "New Vibe" sheet reached from the AI tab on mobile and a
  Compose button in the desktop sidebar. Text input → progress
  stream → 12-track list + blurb → "Play" loads the queue.
- Settings → **LLM** section (new row): Ollama URL (default
  `http://localhost:11434`), `test connection` button, model-status
  dot (green / yellow / red), inline `ollama pull qwen3:1.7b` hint
  when the model is absent.
- Engine reuses slice-5 `FlowScorer` and `Camelot` unmodified — the
  flow step calls `FlowScorer.scoreOrReject` with the same rules.

**Non-goals**

- **LLM on phone this slice.** Slice 8 owns Cactus, weight shipping,
  first-run warm-up, and the Android side of Settings.
- **Cloud LLM providers.** `docs/spec.md` locks Prism fully local; no
  OpenAI / Anthropic / Groq / Together routes.
- Streaming **playback** of picks while the LLM is still thinking —
  the 12 are returned whole; "Play" starts the full queue.
- User-editable prompts, temperature, or system messages.
- Tool calling beyond JSON mode. Qwen3's `<tool_call>` tokens are
  parsed defensively but not invoked.
- Fine-tuning, LoRA, multi-model routing, or auto-pull of weights.
- Persisted playlist library, naming, sharing. Results are ephemeral
  unless the user drags rows into PlayNext / Upcoming.
- Cancellation mid-generate beyond "close the sheet" (which cancels
  the active `dio` request via `CancelToken`).
- Any change to radio semantics, kNN, or mood browse.

## 3. Dependencies

Depends on: 5
Unblocks: 8

Slice 5 contributes `packages/playlist_engine`, `FlowScorer`,
`Camelot`, the `PlaylistRepo` port, and the pure-Dart-engine
discipline. Slice 4 contributes the embedding table, `TrackStatus.ready`
filter, and the scalar mood/BPM/era columns. Slice 1 contributes
`Track`, `QueueService`, `PlaybackService` for end-to-end play.
Slice 8 consumes the same `LlmBackend` + `PlaylistEngine` — its
deliverable is a Cactus-backed `LlmBackend`; any behavioural drift
is a slice-8 bug, not an engine bug.

## 4. Docs to refresh

Run every command before any Dart; save a ≤5-line "API summary" per
library in a scratch file to catch training-data drift. Ollama and
Qwen3 both evolve fast; local memory is unreliable.

### Ollama REST API — `/api/generate`, `/api/chat`, JSON mode

- `WebFetch https://github.com/ollama/ollama/blob/main/docs/api.md`
  — endpoint list, body schema, stream format, `format`, `options`
  (temperature, num_ctx, seed), `keep_alive`.
- `WebFetch https://github.com/ollama/ollama/blob/main/docs/modelfile.md`
  — confirm `qwen3:1.7b` chat template renders `<|im_start|>` /
  `<|im_end|>` correctly.
- **Summary:** streaming is newline-delimited JSON
  (`application/x-ndjson`), one object per chunk with `response`,
  `done`, `eval_count`. `format: "json"` forces strict JSON; newer
  builds accept `format: <JSON Schema object>` for schema-constrained
  decoding — fall back to `"json"` on 400. `keep_alive: "10m"` pins
  the model between the two prompts.

### Qwen3 chat template + reserved tokens

- `WebFetch https://huggingface.co/Qwen/Qwen3-1.7B` — chat template,
  reserved tokens (`<|im_start|>`, `<|im_end|>`, `<tool_call>`,
  `<think>` if present).
- **Summary:** `/api/chat` applies the template; we pass
  `{role, content}` objects. Qwen3 is whitespace-sensitive in JSON
  outputs — trim + strip code fences before parsing. Strip any
  leading `<think>…</think>` defensively.

### `dio` — streaming, cancel tokens, timeouts

- `resolve-library-id libraryName: "dio"` + `query-docs
  topic: "ResponseType.stream CancelToken receiveTimeout BaseOptions"`.
- `WebFetch https://pub.dev/packages/dio` — the stream API shape
  has shifted between 5.x minors.
- **Summary:** `Dio(BaseOptions(connectTimeout: 5s, receiveTimeout:
  60s))`. Streaming: `Options(responseType: ResponseType.stream)`;
  body is `ResponseBody` with `Stream<Uint8List>`. `CancelToken`
  per request; cancel on sheet close. `dio` is locked per
  `docs/plans/README.md` — do not reintroduce `http`.

### Dart `Stream` token fan-out + `flutter_riverpod`

- `WebFetch https://api.dart.dev/stable/dart-async/Stream-class.html`
  — `asBroadcastStream`, `StreamTransformer`.
- `resolve-library-id libraryName: "flutter_riverpod"` + `query-docs
  topic: "AsyncNotifierProvider family stream state invalidate"`.
- **Summary:** decode ndjson via
  `utf8.decoder.bind(stream).transform(LineSplitter()).map(jsonDecode)`.
  Expose a broadcast stream so progress card + debug log both listen;
  UI coalesces at 60 ms. `NewVibeSheet` state lives in an
  `AsyncNotifierProvider.family<NewVibeState, String>` advancing
  through `PlaylistStep` values; `invalidate(...)` retries.

## 5. Architecture & data flow

```
 NewVibeSheet  ──▶  PlaylistEngine.generate(vibe, llm, repo, length: 12)

 (a) INTENT   llm.buildIntent(vibe) → /api/chat qwen3:1.7b, temp 0.1,
              format: JSON Schema (fallback: "json"), keep_alive 10m
              → Intent { mood_targets, bpm_range, era, energy_arc,
                         seed_tracks, seed_keywords, narrative }
              retry ≤2 repair prompts on JSON parse failure
                          │
                          ▼
 (b) POOL     repo.candidatePoolByIntent(intent, poolSize: 200)
              SELECT id FROM tracks WHERE status='ready' AND mood
              filters AND bpm BETWEEN ? AND ? AND era match, ORDER
              BY primary mood col LIMIT 200
              relax if |pool| < length*4 (§10 risk #5)
                          │
                          ▼
 (c) RANK     centroid = seedTracks.isNotEmpty
                 ? mean(embeddings) : meanEmbeddingForKeywords(kw)
              rank pool by cosine(centroid, c.embedding) desc → top-40
                          │
                          ▼
 (d) FLOW     top-40 → ordered 20  (reuse slice-5 FlowScorer + Camelot)
              greedy argmax of centroidSim · FlowScorer bonus
              hard rules: same-artist window 3, |ΔBPM| ≤ 15 (25 under
              "intense"), Camelot bonus/penalty
              energyArc ⇒ pseudo-RadioSession chips (build/wave/flat/descend)
                          │
                          ▼
 (e) NARRATE  llm.refine(intent, ordered20) → /api/chat, temp 0.7,
              format: "json"
              → FinalPass { swaps: ≤4 {dropIndex, insertTrackId}, blurb }
              apply swaps (source IDs from remaining top-40),
              re-flow-score swapped positions only, trim to 12
                          │
                          ▼
 PlaylistResult { tracks (12), blurb, intent } → NewVibeSheet
 ─ "Play" → QueueService.loadContext(tracks, 0); PlaybackService.play()
```

`packages/playlist_engine` imports `LlmBackend` but never Ollama.
`packages/llm_desktop` implements `LlmBackend` but never speaks to the
DB. `packages/core` provides the `TrackRepo` adapter over `CacheDb`.
Apps wire them together. Same orthogonality discipline as slice 5.

## 6. File layout (new files only)

```
/packages/llm_desktop/pubspec.yaml
/packages/llm_desktop/lib/llm_desktop.dart               # barrel
/packages/llm_desktop/lib/src/ollama_config.dart         # url, model, keepAlive
/packages/llm_desktop/lib/src/ollama_client.dart         # dio wrapper
/packages/llm_desktop/lib/src/ollama_backend.dart        # implements LlmBackend
/packages/llm_desktop/lib/src/ollama_health.dart         # ping, model list, pull
/packages/llm_desktop/lib/src/ndjson_decoder.dart        # Stream<Uint8List> → Stream<Map>
/packages/llm_desktop/lib/src/json_repair.dart           # fence/trim/think-strip
/packages/llm_desktop/test/ollama_client_test.dart
/packages/llm_desktop/test/ollama_backend_test.dart
/packages/llm_desktop/test/json_repair_test.dart
/packages/playlist_engine/lib/playlist_engine.dart       # existing barrel + PlaylistEngine class
/packages/playlist_engine/lib/llm_backend.dart           # LlmBackend + LlmProgress
/packages/playlist_engine/lib/intent.dart                # Intent + MoodTarget + EnergyArc
/packages/playlist_engine/lib/final_pass.dart            # FinalPass + Swap
/packages/playlist_engine/lib/playlist_result.dart       # PlaylistResult
/packages/playlist_engine/lib/prompts/intent_prompt.dart # system + kIntentSchema literal
/packages/playlist_engine/lib/prompts/narrative_prompt.dart
/packages/playlist_engine/lib/prompts/mood_lookup.dart   # ~40 adjectives → 5 moods
/packages/playlist_engine/test/playlist_engine_test.dart # end-to-end with FakeLlmBackend
/packages/playlist_engine/test/intent_prompt_test.dart
/packages/playlist_engine/test/flow_reuse_test.dart
/packages/core/lib/src/db/track_repo_impl.dart           # extends PlaylistRepoImpl
/packages/core/test/track_repo_impl_test.dart
/apps/mobile/lib/screens/new_vibe.dart                   # NewVibeSheet + result list
/apps/mobile/lib/widgets/llm_progress_card.dart          # step + token preview + cancel X
/apps/mobile/lib/widgets/playlist_result_card.dart       # blurb + 12 rows + "Play" FAB
/apps/mobile/lib/providers/llm_providers.dart
/apps/mobile/lib/providers/playlist_engine_providers.dart
/apps/mobile/lib/shell/settings_llm_section.dart         # Settings → LLM row
```

Existing files edited additively: `settings_screen.dart` appends the
LLM section below the slice-4 Library/Playback rows; `AppShell` adds
the AI tab on mobile and the "Compose" sidebar item on desktop;
`app.dart` adds a named route `/new-vibe`.

## 7. Interfaces & key types

```dart
// packages/playlist_engine/lib/llm_backend.dart
abstract class LlmBackend {
  /// Stage A — vibe → Intent. Temperature 0.1 in the implementer.
  Future<Intent> buildIntent(String prompt);
  /// Stage E — ordered candidates → FinalPass. Temperature 0.7.
  Future<FinalPass> refine(Intent intent, List<Track> candidates);
  /// Token-by-token progress. Non-streaming backends emit once per pass.
  Stream<LlmProgress> get progress;
}
class LlmProgress { final PlaylistStep step; final String? tokenChunk; final bool done; }
enum PlaylistStep { intent, pool, rank, flow, narrative, ready }

// packages/playlist_engine/lib/intent.dart
enum EnergyArc { build, wave, flat, descend }
class MoodTarget {        // unknown adjectives snap via prompts/mood_lookup.dart
  final String mood;      // one of: happy | sad | aggressive | relaxed | party
  final double? min, max; // parsed from ">=0.5", "<=0.3", "0.4..0.7"
}
class Intent {
  final List<MoodTarget> moodTargets;
  final (int, int)? bpmRange;          // e.g. (70, 110)
  final (int, int)? era;               // inclusive year range
  final EnergyArc energyArc;
  final int durationMinutes;           // hint; trimmed to 12 tracks
  final List<int> seedTracks;          // optional
  final List<String> seedKeywords;
  final String narrative;              // ≤240 chars
  Intent copyRelaxed(RelaxationLevel l);
  factory Intent.fromJson(Map<String, dynamic> j);
  static Intent fallback(String vibe);
}

// packages/playlist_engine/lib/final_pass.dart
class Swap { final int dropIndex; final int insertTrackId; }
class FinalPass { final List<Swap> swaps; final String blurb; }

// packages/playlist_engine/lib/playlist_result.dart
class PlaylistResult {
  final List<Track> tracks;   // length == length (default 12)
  final String blurb;         // already trimmed
  final Intent intent;
  final PlaylistDebug debug;  // timings, repair count, swaps
}

// packages/playlist_engine/lib/playlist_engine.dart  (appends to slice-5 barrel)
class PlaylistEngine {
  const PlaylistEngine({
    FlowScorer flow = const FlowScorer(),
    int poolSize = 200, int rankedTop = 40, int flowedTop = 20,
  });
  /// Runs the six-step pipeline. Never throws on malformed LLM output
  /// — degrades to flow-scored order + default blurb on exhausted
  /// repair budget (§10 risk #1).
  Future<PlaylistResult> generate({
    required String vibe, required LlmBackend llm,
    required TrackRepo repo, int length = 12,
  });
}

// packages/playlist_engine/lib/repo.dart — TrackRepo extends slice-5 PlaylistRepo
abstract class TrackRepo extends PlaylistRepo {
  Future<List<int>> candidatePoolByIntent(Intent intent,
      {int poolSize = 200, RelaxationLevel relax = RelaxationLevel.strict});
  Future<Float32List> meanEmbeddingForKeywords(List<String> keywords);
  Future<Track> trackOf(int trackId);
}
enum RelaxationLevel { strict, loose, veryLoose }
```

The intent prompt's enforced schema, inlined verbatim as a Dart
string literal so `intent_prompt_test.dart` can lock it:

```dart
// packages/playlist_engine/lib/prompts/intent_prompt.dart
const String kIntentSchema = r'''
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["mood_targets", "energy_arc", "duration_minutes", "narrative"],
  "properties": {
    "mood_targets": {
      "type": "array", "minItems": 1, "maxItems": 5,
      "items": {
        "type": "object", "required": ["mood"], "additionalProperties": false,
        "properties": {
          "mood": {"type":"string","enum":["happy","sad","aggressive","relaxed","party"]},
          "min":  {"type":"number","minimum":0,"maximum":1},
          "max":  {"type":"number","minimum":0,"maximum":1}
        }
      }
    },
    "bpm_range": {"type":"array","minItems":2,"maxItems":2,
                  "items":{"type":"integer","minimum":40,"maximum":220}},
    "era":       {"type":"array","minItems":2,"maxItems":2,
                  "items":{"type":"integer","minimum":1950,"maximum":2100}},
    "energy_arc":       {"type":"string","enum":["build","wave","flat","descend"]},
    "duration_minutes": {"type":"integer","minimum":15,"maximum":240},
    "seed_tracks":   {"type":"array","items":{"type":"integer"},"maxItems":3,"default":[]},
    "seed_keywords": {"type":"array","items":{"type":"string"},"maxItems":8,"default":[]},
    "narrative":     {"type":"string","maxLength":240}
  }
}
''';
```

```dart
// packages/llm_desktop/lib/src/ollama_config.dart
class OllamaConfig {
  final Uri baseUrl;           // default http://localhost:11434
  final String model;          // default "qwen3:1.7b"
  final Duration keepAlive;    // default 10m
  final Duration connectTimeout, receiveTimeout;
}
// packages/llm_desktop/lib/src/ollama_backend.dart
class OllamaBackend implements LlmBackend {
  OllamaBackend(OllamaClient c, {OllamaConfig? config});
  Future<OllamaHealth> health();                 // ping + model list
  // overrides: buildIntent, refine, progress
}
enum OllamaHealthStatus { up, upModelMissing, down }
class OllamaHealth { final OllamaHealthStatus status; final String? detail; }
```

## 8. Implementation steps

Ordered. Each step names its files and a one-line pass criterion.
Steps 3, 6, and 8 are the highest-risk.

1. **Refresh docs (§4).** Save five ≤5-line API summaries. Confirm
   exact spelling for `format: <schema>` vs `format: "json"`, ndjson
   decoding, and `keep_alive`. **Pass:** notes exist.

2. **Create `packages/llm_desktop`.** `pubspec.yaml`, barrel,
   register in `melos.yaml`. **Pass:** `melos bootstrap` adds the
   path dep; `dart analyze` clean.

3. **`NdjsonDecoder` + `OllamaClient`.** `ndjson_decoder.dart` composes
   `utf8.decoder` + `LineSplitter` + `JsonDecoder` as a
   `StreamTransformer`. `OllamaClient` wraps `dio` with `generate`,
   `chat`, `tags`, `pull`; each streaming call returns
   `Stream<Map<String, dynamic>>` gated by `CancelToken`. **Pass:**
   `ollama_client_test.dart` vs `MockAdapter` with a 4-chunk ndjson
   body; assembled text equals concatenated `response` fields.

4. **`OllamaBackend.buildIntent`.** Build chat request:
   `messages=[{role:system, content: kIntentSystem}, {role:user,
   content: vibe}]`; `stream:true`; `format`: JSON Schema object
   parsed from `kIntentSchema` (fallback `"json"` on 400);
   `options:{temperature:0.1, num_ctx:4096, seed:-1}`;
   `keep_alive: config.keepAlive`. Collect `response` chunks, parse
   JSON, validate via a tiny schema checker, call `MoodLookup.snap`
   on unknown moods. **Pass:** fake-client valid intent → `Intent`;
   malformed payload → `LlmJsonParseException`.

5. **Repair loop in `PlaylistEngine.generate`.** On
   `LlmJsonParseException`, call `buildIntent` again with a repair
   preamble naming the specific violation. Max 2 repairs; then
   `Intent.fallback(vibe)` — a hand-written mapper that keyword-
   classifies the raw vibe into one of the 5 moods. **Pass:** fake
   LLM emits garbage twice then good JSON → `PlaylistResult` with
   `debug.repairCount == 2`.

6. **`TrackRepo.candidatePoolByIntent`.** Dynamic SQL, strict form:

   ```sql
   SELECT id FROM tracks
    WHERE status = 'ready'
      AND (:has_bpm = 0 OR bpm BETWEEN :bpm_lo AND :bpm_hi)
      AND (:has_era = 0 OR year BETWEEN :era_lo AND :era_hi)
      AND (:mood_happy_min   IS NULL OR mood_happy      >= :mood_happy_min)
      AND (:mood_sad_min     IS NULL OR mood_sad        >= :mood_sad_min)
      AND (:mood_relaxed_min IS NULL OR mood_relaxed    >= :mood_relaxed_min)
      AND (:mood_aggr_min    IS NULL OR mood_aggressive >= :mood_aggr_min)
      AND (:mood_party_min   IS NULL OR mood_party      >= :mood_party_min)
    ORDER BY (<primary mood col>) DESC
    LIMIT :pool_size;
   ```

   `loose` widens BPM by ±10 and drops era; `veryLoose` drops all
   non-primary mood clauses and doubles `LIMIT`. **Pass:** strict
   `{sad>=0.5, bpm:70..110}` rows all satisfy predicates; `loose`
   returns ≥1.5× more; `veryLoose` ≥3×.

7. **Centroid ranking.** In `_rank`: if `intent.seedTracks` non-empty,
   centroid = L2-normalized mean of their embeddings. Else centroid
   = `repo.meanEmbeddingForKeywords(intent.seedKeywords)` which
   averages the embeddings of tracks whose mood matches the keyword
   table in `prompts/mood_lookup.dart`. Cosine over the pool →
   descending sort → top-40. **Pass:** ranks a known-close track
   above a known-far one on a seeded fake.

8. **Flow ordering over 40 → 20.** Pure-Dart greedy:
   - Start with the top-ranked track at index 0.
   - For `i` in 1..19, compute per remaining candidate `c`:
     `score = centroidSim(c) * FlowScorer.scoreOrReject(candidate:
     c, previous: picks[i-1], session: pseudoSession(intent))`.
   - `pseudoSession` translates `intent.energyArc` into a
     `RadioSession`-shaped object whose chips express the arc:
     `build → faster`, `descend → slower`, `wave → alternating`,
     `flat → none`.
   - Append the argmax. If `FlowScorer` rejects everything
     remaining, drop the artist-window rule for one slot then
     restore it.
   **Pass:** `flow_reuse_test.dart` imports `FlowScorer` by the
   same path slice 5 uses; asserts no same-artist within 3 picks
   and monotone-BPM on `energyArc == build`.

9. **`OllamaBackend.refine`.** Same chat pattern as step 4 but:
   system = `kNarrativeSystem`; user = 20 ordered tracks serialized
   as `id | title | artist | bpm | key | year`; `format: "json"`;
   `temperature: 0.7`. Parse into `FinalPass`. Drop swaps whose
   `insertTrackId` is not in the top-40 (record in
   `debug.invalidSwaps`). Truncate blurb at the second sentence
   terminator or 240 chars. **Pass:** fake-LLM returns a valid
   swap-and-blurb JSON → engine applies swaps, re-flow-scores
   swapped positions, trims to 12.

10. **Prompt texts** (condensed; final files hold the full strings):

    ```
    kIntentSystem (temp 0.1):
      Convert the user's free-text "vibe" into strict JSON. Return
      ONLY JSON, no prose, no code fences. Moods ∈ {happy, sad,
      aggressive, relaxed, party}. Arcs ∈ {build, wave, flat,
      descend}. BPM ∈ [40,220]. Era ∈ [1950,2100]. duration ∈
      [15,240]. Prefer omitting bpm_range/era over inventing.
      seed_keywords = short texture nouns ("dream pop", "no vocals");
      leave seed_tracks empty. Output MUST validate against:
      {kIntentSchema}
      Example in:  "rainy Sunday morning, low BPM, no vocals"
      Example out: {"mood_targets":[{"mood":"relaxed","min":0.5},
        {"mood":"aggressive","max":0.2}],"bpm_range":[60,95],
        "energy_arc":"flat","duration_minutes":45,"seed_tracks":[],
        "seed_keywords":["ambient","instrumental","rainy"],
        "narrative":"calm rainy morning, no vocals"}

    kNarrativeSystem (temp 0.7):
      Given (1) intent, (2) 20 ordered candidates, return STRICT
      JSON with ≤4 swaps that improve narrative flow and a blurb
      ≤2 sentences. MAY drop / promote; MUST NOT invent ids, swap
      >4, or reorder beyond declared swaps (engine re-orders).
      Shape: {"swaps":[{"dropIndex":<0..19>,"insertTrackId":<int>}],
              "blurb":"<=2 sentences"}
    ```

    **Pass:** `intent_prompt_test.dart` locks `kIntentSystem` byte-
    for-byte; schema substitution renders valid JSON Schema.

11. **`OllamaHealth` + Settings row.** `ollama_health.dart` calls
    `GET /api/tags`. Mapping: 200 containing `{name: "qwen3:1.7b"}`
    → `up`; 200 without it → `upModelMissing`; connection refused /
    timeout → `down`. `settings_llm_section.dart` renders URL
    field, Test button, status dot, and a selectable
    `ollama pull qwen3:1.7b` on `upModelMissing`. **Pass:** with
    Ollama + model → green; stop Ollama → red within 5 s; `ollama
    rm qwen3:1.7b` → yellow with copyable pull hint.

12. **Providers.** `llm_providers.dart`: `StateProvider<OllamaConfig>`
    (URL persisted via slice-4 shared prefs), derived
    `Provider<OllamaClient>`, `Provider<OllamaBackend>`,
    `StreamProvider<OllamaHealth>` polled every 30 s while Settings
    is open. `playlist_engine_providers.dart`:
    `Provider<PlaylistEngine>`, `Provider<TrackRepo>` adapting
    `CacheDb`, and `AsyncNotifierProvider.family<NewVibeState,
    String>`. **Pass:** widget test drives the notifier through all
    six `PlaylistStep` values against fakes.

13. **`NewVibeSheet`.** Multi-line autofocus text field → "Go" →
    `LlmProgressCard` (current step + last ~400 chars of streamed
    tokens + cancel X) → `PlaylistResultCard` (blurb + 12 rows +
    "Play" FAB). "Play" calls `QueueService.loadContext(tracks, 0)`
    then `PlaybackService.play()`. Close-sheet cancels the
    `CancelToken`. **Pass:** manual — sheet opens from both
    entry points; "rainy Sunday morning, low BPM, no vocals" yields
    12 rows + blurb; Play starts audio.

14. **AI tab / Compose entry.** Mobile `AppShell`: append a fourth
    tab "AI" with a landing card + Compose FAB. Desktop sidebar:
    add "Compose playlist" under Library. Route name `/new-vibe`.
    **Pass:** both platforms reach the sheet in one tap.

15. **Run §11.** **Pass:** every numbered item green.

## 9. Alternatives considered

**(a) Skip flow-scoring; let the LLM order the 40.** Simplest engine:
intent → pool → rank → LLM returns a 12-ordered list + blurb in one
pass. Rejected. (i) Qwen3-1.7B has no reliable internal model of BPM
adjacency or Camelot compatibility, and its training corpus carries
no consistent "sonic flow" label. (ii) Deterministic ordering is
test-auditable; LLM ordering is not, and §11 demands a monotone-BPM
check we cannot assert without a deterministic step. (iii) Serializing
40 full candidates approaches the 4k-token budget. Reconsider only if
LLM quality climbs past the flow scorer's floor — unlikely at 1.7B.

**(b) Skip the narrative pass entirely.** Return the flow-scored 12
with a canned blurb synthesized from `intent.narrative`. Rejected.
The narrative pass is where the playlist earns "vibe" — swaps catch
tracks that fit the mood vector but break the story (an instrumental
hymn in a drive-rock arc). Canned blurbs read robotic. Reconsider if
the swap rate is consistently ≤1 over ~100 generations — then drop
behind a flag, keep the blurb.

**(c) Generate on phone too in this slice.** Cactus's Flutter SDK
works cross-platform but Qwen3-1.7B INT4 needs a ~1 GB weight ship,
a first-run warm-up, and platform-specific NEON/GPU glue — a full-
slice concern. Rejected. Slice 6 proves the engine on the easier
substrate (Ollama) and locks prompts + `LlmBackend`; slice 8 does
the harder ship with the interface frozen.

**(d) Raw `http` instead of `dio`.** Smaller and has a clean streaming
API. Rejected: `docs/plans/README.md` locks `dio` across the stack;
mixing clients adds cognitive load in Settings where slice-2's
MusicBrainz fetcher also uses `dio`. `CancelToken` is cleaner for
mid-generate cancel.

**(e) `/api/generate` with a hand-rolled Qwen3 template.** Gives
direct access to `<|im_start|>` / `<|im_end|>` and tool-call tokens.
Rejected: `/api/chat` with the Modelfile-provided template is the
supported path; slice 6 doesn't need tool calls; keeping template
logic inside Ollama avoids Qwen3 drift when the model is bumped.
`generate` stays available in `OllamaClient`; the backend only calls
`chat`.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | JSON-mode failure — prose, code fences, or schema-invalid JSON. | `json_repair.dart` strips ```` ``` ```` fences, trailing prose, and any leading `<think>…</think>`; in-process schema checker flags the violation; engine retries with a repair prompt naming the specific issue. Max 2 attempts. Then `Intent.fallback(vibe)` runs and the pipeline proceeds with `debug.repairCount == 2`; narrative pass still attempted. User sees a result, not an error. |
| 2 | Ollama daemon not running. | `dio` connect-timeout 5 s maps to `OllamaHealth.down`. `NewVibeSheet` refuses to submit while health is down; CTA becomes "Start Ollama". Settings → LLM shows a red dot and a copy-able `systemctl --user start ollama` hint where the service file is present. |
| 3 | Model not pulled (`qwen3:1.7b` absent). | `OllamaHealth.upModelMissing` → yellow dot. Row renders `ollama pull qwen3:1.7b` as `SelectableText`. We do not auto-pull — `/api/pull` is a background job; a hidden 2 GB download would confuse users, and verification requires the model already present. |
| 4 | Intent asks for an unknown mood ("melancholic", "brooding"). | `prompts/mood_lookup.dart` maps ~40 common adjectives to the 5 classifier moods ("melancholic" → "sad"; "euphoric" → "happy" + "party"). Anything unmapped snaps to the nearest of 5 by a small hard-coded cosine — worst case lands on "relaxed". Unit test locks the table. |
| 5 | Candidate pool returns < 12 (narrow intent or small library). | `|pool| < length*4` triggers retry with `RelaxationLevel.loose` (widen BPM ±10, drop era). Still < 24 → `veryLoose` (primary mood only). Still < length → slice-5's `libraryWideFallback(100)` filtered to `status='ready'`. `debug.relaxationLevel` recorded; UI surfaces "Your library is a little too small for this vibe" when level == `veryLoose` AND pool < 24. |
| 6 | Swaps reference track IDs not in the top-40. | `_applySwaps` drops invalid swaps and records in `debug.invalidSwaps`. Expected occasionally — the narrative LLM only sees 20; may propose an ID from the 20 already at another position. Treated as no-op. |
| 7 | > 4 swaps or > 2 blurb sentences despite instructions. | `FinalPass.fromJson` truncates `swaps` at 4; blurb trimmed at second terminator or 240 chars. Both recorded in `debug`. |
| 8 | `keep_alive` releases the model between intent and narrative. | Default 10 m; two calls fire within ~2 s of each other. Suspiciously slow first narrative chunk (>5 s) logs a warning — a cold reload would surface in §11 item 5 as a timing miss. |
| 9 | Sheet closed mid-generate → partial HTTP stream. | `CancelToken.cancel()` aborts the active `dio` request; `PlaylistEngine.generate` catches `DioException(type: cancel)` and rethrows as `PlaylistCancelled`; sheet ignores on close. |
| 10 | Empty or whitespace-only vibe. | Submit disabled on length 0; length ≥ 1 but all whitespace short-circuits to `Intent.fallback("shuffle")` → library-wide pool → flow-scored 12. Returns a valid (generic) playlist. |
| 11 | Qwen3 emits `<think>` reasoning tokens. | `json_repair.dart` strips leading `<think>…</think>`. Dangling tag → repair path catches on malformed JSON and asks for a clean response. |
| 12 | Identical seed + vibe produce identical playlists. | Acceptable this slice — variety from rewording. `options.seed: -1` gives limited run-to-run variation. `PlaylistResultCard` exposes "Generate again" that invalidates the notifier. |

## 11. Verification

Run in order. Items 1–6 are the slice-6 acceptance; 7–12 cover the
risk matrix and slice-5 reuse contracts.

1. **"rainy Sunday morning, low BPM, no vocals".** Open the sheet;
   submit the exact phrase. Within 15 s on desktop: blurb ≤ 2
   sentences and exactly 12 rows. Spot-listen: plausibly rainy-
   Sunday-morning; no party-BPM outliers; no vocal-forward pop.
   `debug.repairCount` is 0 or 1 in a normal run.
2. **Plays end-to-end.** Tap "Play". Playback starts on track 1;
   all 12 tracks play to completion without manual advance.
3. **Blurb ≤ 2 sentences.** Across 10 generations, every
   `result.blurb` parses to ≤ 2 sentence terminators and ≤ 240 chars.
4. **No same-artist back-to-back.** Across 10 generations, for
   every `i ∈ 1..11`: `tracks[i].artist != tracks[i-1].artist`.
   Additionally, no 3-consecutive-track window shares an artist.
5. **BPM progression within ±15 per step.** For every
   `(tracks[i], tracks[i+1])`: `|Δbpm| ≤ 15`, or a ±50% half/double-
   time jump. On `energy_arc == build`, mean BPM of picks 7–12 ≥
   mean of 1–6.
6. **Settings → LLM test connection.** With `ollama serve` up and
   model pulled: dot green, "Connected; qwen3:1.7b available".
   Stop Ollama, Test → red within 5 s ("Connection refused").
   `ollama rm qwen3:1.7b` → yellow with copyable pull hint.
7. **FlowScorer reuse.** `flow_reuse_test.dart` imports `FlowScorer`
   via the same path slice 5 uses; asserts `PlaylistEngine._flow`
   calls it without wrapping, subclassing, or reimplementation.
8. **Repair path.** Fake `LlmBackend` emits malformed, schema-
   invalid, then valid JSON. `generate` returns a `PlaylistResult`
   with `debug.repairCount == 2`. Pure-garbage fake → engine falls
   back to `Intent.fallback(vibe)` and completes.
9. **Sparse library.** Move most sidecars aside so `ready` ~30.
   Narrow vibe ("aggressive metal, 160+ BPM"). `debug.relaxationLevel`
   reaches `veryLoose`; result still contains 12 tracks.
10. **Unknown mood snap.** Submit "melancholic late-night drive"
    and "euphoric summer party". First → `sad` present. Second →
    `happy` + `party`. No mood outside the 5-enum survives.
11. **Cancel.** Submit a long vibe; close within 2 s. No active
    `dio` request remains. Reopen, submit: completes normally.
12. **Unit + integration tests.** `melos run test` green for
    `ollama_client_test`, `ollama_backend_test`, `json_repair_test`,
    `intent_prompt_test`, `flow_reuse_test`, `playlist_engine_test`,
    `track_repo_impl_test`. Wall-clock < 15 s on a laptop.

## 12. Definition of done

- [ ] `packages/llm_desktop` exists with no Flutter leakage beyond
  `dio`'s own FFI; `dart analyze` clean; `dart test` green.
- [ ] `LlmBackend` has exactly two Futures (`buildIntent`,
  `refine`) plus a `Stream<LlmProgress>`; no Ollama / Cactus types
  leak into it.
- [ ] `PlaylistEngine.generate` returns a `PlaylistResult` with
  exactly `length` tracks (default 12), a blurb ≤ 2 sentences, and
  a non-null `intent` on every call against a non-empty library.
- [ ] Pipeline reuses slice-5 `FlowScorer` and `Camelot` verbatim;
  `flow_reuse_test.dart` locks the import path; no duplicated flow-
  rule code outside slice-5's `flow.dart` and `camelot.dart`.
- [ ] Candidate pool relaxes through `strict → loose → veryLoose →
  libraryWideFallback` and never returns fewer than `length` rows on
  a library with ≥ `length*4` ready tracks.
- [ ] `kIntentSchema` is a single `const String` referenced by the
  intent prompt; `intent_prompt_test.dart` locks it byte-for-byte.
- [ ] `buildIntent` runs at temperature 0.1 with `format: <schema>`
  (or `"json"` fallback) and performs ≤ 2 repair prompts before
  falling back; `refine` runs at 0.7 with `format: "json"`, honours
  ≤ 4 swaps, trims blurb to ≤ 2 sentences / 240 chars.
- [ ] Unknown moods snap to one of `{happy, sad, aggressive, relaxed,
  party}` via `mood_lookup.dart`; no other mood survives
  `Intent.fromJson`.
- [ ] `NewVibeSheet` reachable in one tap from the AI tab on mobile
  and the Compose sidebar on desktop; Settings → LLM row renders URL,
  test button, three-state status dot, and the `ollama pull
  qwen3:1.7b` hint when the model is missing.
- [ ] Sheet close mid-generate cancels the active `dio` request;
  next open works clean; no lingering future.
- [ ] §4 "Docs to refresh" commands were executed and API-summary
  notes written before any Dart file was touched.
- [ ] No deferred-work sentinels — every unfinished item is scoped
  to a later slice and linked here by number (slice 8 for Android
  Cactus parity; slice 7 for typography of the sheet).
