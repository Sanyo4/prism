# Slice 5 — Infinite Radio (`packages/playlist_engine`, seed-kNN + steer chips)

## 1. Context

Slice 5 ships **Infinite Radio**: given a seed (track, album, or
artist), Prism streams an unbounded sequence of sonically related
tracks. The engine is a deterministic pure-Dart pipeline — seed
embedding → `vec0` kNN top-200 → steer-chip re-weight → flow-scorer
→ pick one → append to `ConcatenatingAudioSource`. A lookahead of 5
tracks stays pre-picked so the player never stalls at the tail. The
user steers with a locked vocabulary of 10 chips that decay over
~10 picks. Slice 5 is explicitly **no LLM dependency** — radio must
work cold on an airplane-mode phone the first time the user opens
the app after slices 1+4 land, identically on Linux. The LLM
arrives in slice 6 as an orthogonal code path that reuses this
slice's flow scorer and Camelot helper without modification.

This slice also introduces `packages/playlist_engine` — the first
platform-agnostic pure-Dart package in the tree. Zero Flutter, zero
`dart:io`, zero `sqlite3`. It talks to the world through a
`PlaylistRepo` port implemented in `packages/core`. That discipline
is what lets slice 6's `PlaylistEngine` (LLM-driven, 12-track one-
shot) drop in beside: engine tests run under `dart test` against an
in-memory fake, never touching SQLite. Name locked by `docs/spec.md`.

End-to-end: user long-presses a row, album cell, or artist cell,
picks "Start radio from this ___"; Prism builds a `RadioSession`,
runs `next(...)` five times to fill the lookahead, and from then on
every queue advance fires one `next(...)` that appends one track.
Now Playing grows a "RADIO" badge and chip strip; Queue reads
"Radio · seeded from '<title>'"; Home gets a Radio row showing
three recent seeds.

## 2. Goals / Non-goals

**Goals**

- `packages/playlist_engine` — pure Dart, no Flutter / `dart:io` /
  SQLite; deps `meta`, `collection`; dev `test`, `lints`.
  Integration is one `PlaylistRepo` port.
- `RadioEngine` with three seeds: `fromTrack(Track)`,
  `fromAlbum(Album)`, `fromArtist(Artist)`. Album/artist seeds are
  the L2-normalized mean of contributing track embeddings.
- `RadioSession` carries `seedEmbedding: Float32List` (1280),
  `Map<SteerChip, ChipState>` with per-chip TTL, `List<int>
  history` (most-recent last, session-scoped), `int lookahead = 5`,
  and a `SeedRef` naming the seed for UI.
- `RadioEngine.next(session, repo)` → one `PickResult` per call.
  Top-200 via `repo.knnByEmbedding(seed, k=200)` → chip re-weight
  → flow scorer → argmax. Same pure function on both platforms.
- `FlowScorer` enforces: no same-artist within 3 picks; |ΔBPM| ≤ 15
  unless `moreIntense` (widens to 25); hard de-dup against last 20
  history ids. Camelot distance ≤ 1 is a soft bonus; ≥ 3 a penalty.
- **Steer chips (locked vocabulary, 10 total)**:
  - Mood: `happier`, `sadder`, `calmer`, `moreIntense`
  - Tempo: `slower`, `faster`
  - Era: `newer`, `older`
  - Texture: `moreLikeThisArtist`, `differentArtists`
  Per-chip linear TTL decay over 10 picks; reselect resets to 10.
  UI enforces mutual exclusion on each opposing pair.
- `FlowScorer` and `Camelot` are slice-6-reusable — no radio-
  specific state, pure functions. `flow_test.dart` imports them
  from outside the radio call site to prove API stability.
- UI: "RADIO" badge above Now Playing title, `SteerChipBar` above
  AeroSlider (radio-only), Queue header `Radio · seeded from
  '<title>'`, Home `RadioHomeCard` with ≤3 recent seeds.
- Long-press on tracks, albums, artists gains "Start radio from
  this ___".
- `QueueService.radioMode` flag: on → PlayNext at head, picks
  append to Upcoming; off → slice-1 semantics unchanged.

**Non-goals**

- **Server-side radio, cloud recommenders** (Last.fm
  `track.getSimilar`, Spotify Radio, MusicBrainz): all out.
- Any LLM involvement. Slice 6 adds `PlaylistEngine`; radio never
  dispatches to Ollama or Cactus.
- User-editable chip vocabulary or per-chip weight sliders.
- Persistent sessions across app restart. `RecentSeedsStore` is the
  one-tap restore from the Home card.
- Album/artist detail screens (slice 2 owns). This slice adds only
  the long-press action row.
- Explicit negative feedback UI. Skip-spam triggers implicit
  history weighting (§10 risk 5).
- Changes to ReplayGain, gapless, or playback polish — slice 1
  owns those; radio inherits via append.
- Cross-device session sync.

## 3. Dependencies

Depends on: 4
Unblocks: 6

Slice 4 contributes `CacheDb.knnByEmbedding`, `TrackStatus.ready`
(the only status radio considers), the embedding byte format (LE
IEEE-754 float32, 5120 bytes for 1280 dims), and `SidecarReader`'s
guarantee that every `ready` row has a usable embedding. Slice 1
contributes `Track`, `QueueService`, `PlaybackService`, and the
`ConcatenatingAudioSource` radio appends into. Slice 6 requires
only that `packages/playlist_engine` exists with `FlowScorer` +
`Camelot` callable; no radio-specific types leak into the LLM path.

## 4. Docs to refresh

Run every command before any Dart; save a ≤5-line "API summary" per
library in a scratch file to catch training-data drift.

### `sqlite-vec` (`vec0`) — kNN query shape, LIMIT + nearest

- `WebFetch https://github.com/asg017/sqlite-vec` — README, `vec0`
  filename, min SQLite version.
- `WebFetch https://github.com/asg017/sqlite-vec/blob/main/docs/api-reference.md`
  — exact `MATCH` / `k =` spelling, whether `LIMIT` or `k` is
  authoritative, `vec_distance_l2` vs `_cosine`, `vec_f32` bind
  helper, `rowid` stability across `INSERT OR REPLACE`.
- **Summary:** bind seed as `vec_f32(?)` over a 5120-byte LE
  float32 blob. Canonical kNN:
  ```sql
  SELECT track_id, vec_distance_l2(embedding, vec_f32(?)) AS d
    FROM track_embeddings
   WHERE embedding MATCH vec_f32(?) AND k = 200
   ORDER BY d;
  ```
  Radio uses L2 internally; chip re-weight maps L2 → cosine-like
  sim via `sim = exp(-d / tau)`, `tau = 0.5`.

### `just_audio` — `ConcatenatingAudioSource.add` / `insertAll`

- `resolve-library-id libraryName: "just_audio"` + `query-docs
  topic: "ConcatenatingAudioSource add insertAll while playing
  gapless"`.
- **Summary:** `add(AudioSource)` and `insertAll(index,
  List<AudioSource>)` mutate in-place without interrupting playback.
  Confirm gapless behavior when appending at tail while current
  index is the previous tail. Radio never shuffles the internal
  source; in radio mode `QueueService` is append-only.

### Flutter `AnimatedList` / `AnimatedSwitcher`

- `WebFetch https://api.flutter.dev/flutter/widgets/AnimatedList-class.html`
- `WebFetch https://api.flutter.dev/flutter/widgets/AnimatedSwitcher-class.html`
- **Summary:** `AnimatedList.of(context).insertItem(i)` +
  `removeItem(i, builder)` animate queue rows. `SteerChipBar` uses
  `AnimatedSwitcher` keyed on the active-chip set hash. Slice 5
  ships the default 250 ms fade+slide; slice 7 polishes.

### `collection` — priority queue

- `resolve-library-id libraryName: "collection"` + `query-docs
  topic: "HeapPriorityQueue"`.
- **Summary:** `HeapPriorityQueue<_Scored>` argmaxes 200 candidates
  in O(n log n) without a full sort; slice 6 reuses for top-12.

## 5. Architecture & data flow

```
 UI trigger (long-press / Home Radio card)
     │
     ▼  RadioEngine.fromTrack / fromAlbum / fromArtist
        (repo.meanEmbeddingFor... for album / artist)
     ▼  RadioSession { seed, chips, history, lookahead }
     ▼
 ┌──────────────────────────────────────────────────────┐
 │                 RadioEngine.next()                   │
 │  repo.knnByEmbedding(seed, k=200)                    │
 │     → Candidate[200] { id, artist, bpm, key, year,   │
 │                        mood_*, l2_dist }             │
 │     → Steer-chip soft re-weight                      │
 │          score = sim · Π chipWeight(chip, cand)      │
 │     → FlowScorer.scoreOrReject                       │
 │          reject: same-artist-in-3, history,          │
 │                  |ΔBPM|>window                       │
 │          bonus:  Camelot dist ≤1 (+), ≥3 (−)         │
 │     → final = sim · chipWeight · flowBonus           │
 │     → HeapPriorityQueue.first → PickResult           │
 └──────────────────────────────────────────────────────┘
     │
     ▼  LookaheadManager — 5-deep ring; on advance, pops
        one and calls next(); appends AudioSource via
        ConcatenatingAudioSource.add. just_audio keeps
        playing; the player never stalls while radio is on.
```

**Ownership.** `packages/playlist_engine` owns `RadioEngine`,
`RadioSession`, `SteerChip`, `FlowScorer`, `Camelot`, `PlaylistRepo`.
`packages/core` owns `PlaylistRepoImpl` over `CacheDb`. `apps/mobile`
(with `packages/playback` for the flag) owns `LookaheadManager`,
radio providers, `radioMode`, and all widgets.

`packages/playlist_engine` imports nothing from `packages/core` or
Flutter. Slice 6 adds `lib/playlist_engine.dart` beside
`lib/radio_engine.dart`, sharing `FlowScorer`, `Camelot`, and the
same `PlaylistRepo` port.

## 6. File layout (new files only)

```
/packages/playlist_engine/pubspec.yaml                # pure Dart
/packages/playlist_engine/lib/playlist_engine.dart    # barrel
/packages/playlist_engine/lib/radio_engine.dart       # fromTrack/Album/Artist, next()
/packages/playlist_engine/lib/radio_session.dart      # RadioSession + SeedRef
/packages/playlist_engine/lib/steer_chip.dart         # SteerChip + ChipState
/packages/playlist_engine/lib/chip_weights.dart       # per-chip scoring kernels
/packages/playlist_engine/lib/flow.dart               # FlowScorer + rules config
/packages/playlist_engine/lib/camelot.dart            # Camelot wheel + key parser
/packages/playlist_engine/lib/repo.dart               # PlaylistRepo port
/packages/playlist_engine/lib/pick_result.dart        # PickResult + ScoreBreakdown
/packages/playlist_engine/test/radio_engine_test.dart
/packages/playlist_engine/test/flow_test.dart
/packages/playlist_engine/test/camelot_test.dart
/packages/playlist_engine/test/chip_weights_test.dart
/packages/playlist_engine/test/fakes/fake_repo.dart
/packages/core/lib/src/db/playlist_repo_impl.dart     # adapter CacheDb → port
/packages/core/test/playlist_repo_impl_test.dart
/packages/playback/lib/src/radio_mode.dart            # QueueService.radioMode flag
/apps/mobile/lib/providers/radio_providers.dart       # sessions + lookahead
/apps/mobile/lib/radio/lookahead_manager.dart         # 5-deep ring, append driver
/apps/mobile/lib/radio/recent_seeds_store.dart        # last-3 seeds, shared prefs
/apps/mobile/lib/widgets/radio_badge.dart             # "RADIO" pill
/apps/mobile/lib/widgets/steer_chip_bar.dart          # AnimatedSwitcher strip
/apps/mobile/lib/widgets/radio_seed_header.dart       # Queue view header
/apps/mobile/lib/widgets/radio_home_card.dart         # Home row, 3 recent
/apps/mobile/lib/screens/radio_context_sheet.dart     # long-press sheet
```

Existing files touched (edits are additive): mount `RadioBadge` +
`SteerChipBar` in `now_playing_screen.dart`; mount
`RadioSeedHeader` in `queue_screen.dart` above Upcoming; mount
`RadioHomeCard` in `home_screen.dart` below the slice-4 mood chip
row; add long-press entries in `tracks_screen.dart`; add
`radioMode` flag + append-on-advance hook in `queue_service.dart`
(slice-1 invariants preserved when off).

## 7. Interfaces & key types

```dart
// packages/playlist_engine/lib/steer_chip.dart
enum SteerChip {
  happier, sadder, calmer, moreIntense,
  slower, faster, newer, older,
  moreLikeThisArtist, differentArtists,
}
class ChipState {                         // 0..10 ticks, linear decay
  final int ticksRemaining;
  const ChipState(this.ticksRemaining);
  double get weight => ticksRemaining / 10.0;
  ChipState tick() => ChipState((ticksRemaining - 1).clamp(0, 10));
  bool get isActive => ticksRemaining > 0;
}
// UI-enforced; engine asserts as defense-in-depth.
const Map<SteerChip, SteerChip> kChipConflicts = {
  SteerChip.calmer: SteerChip.moreIntense, SteerChip.moreIntense: SteerChip.calmer,
  SteerChip.slower: SteerChip.faster,      SteerChip.faster:      SteerChip.slower,
  SteerChip.newer:  SteerChip.older,       SteerChip.older:       SteerChip.newer,
  SteerChip.moreLikeThisArtist: SteerChip.differentArtists,
  SteerChip.differentArtists:   SteerChip.moreLikeThisArtist,
};
```

```dart
// packages/playlist_engine/lib/radio_session.dart
sealed class SeedRef { String get label; }
class TrackSeed  extends SeedRef { final int trackId; final String title; }
class AlbumSeed  extends SeedRef { final String albumKey; final String title; }
class ArtistSeed extends SeedRef { final String artist; final String label; }

class RadioSession {
  final SeedRef seed;
  final Float32List seedEmbedding;          // 1280 dims, L2-normalized
  final Map<SteerChip, ChipState> chips;
  final List<int> history;                  // most recent last
  final int lookahead;                      // default 5
  final int? lastPickArtistId;
  RadioSession copyAfterPick(int trackId, String artistKey);
  RadioSession withChipToggled(SteerChip chip);   // → 10 ticks
  RadioSession withChipCleared(SteerChip chip);
}
```

```dart
// packages/playlist_engine/lib/repo.dart
abstract class PlaylistRepo {
  Future<Float32List>  embeddingOf(int trackId);
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey);
  Future<Float32List?> meanEmbeddingForArtist(String artist);
  Future<List<KnnHit>> knnByEmbedding(Float32List seed, {int k = 200});
  Future<CandidateMeta> metaOf(int trackId);
  Future<List<int>>     libraryWideFallback({int limit = 100});
}
class KnnHit { final int trackId; final double l2Distance; }
class CandidateMeta {
  final int trackId; final String artistKey, title, key; final int? year;
  final double bpm, moodHappy, moodSad, moodRelaxed, moodAggressive,
               moodParty, danceability, voiceInstrumental;
}
```

```dart
// packages/playlist_engine/lib/radio_engine.dart
class RadioEngine {
  const RadioEngine({
    FlowScorer flow = const FlowScorer(),
    ChipWeights weights = const ChipWeights(),
  });
  static Future<RadioSession> fromTrack (Track  t, PlaylistRepo r);
  static Future<RadioSession> fromAlbum (Album  a, PlaylistRepo r);
  static Future<RadioSession> fromArtist(Artist a, PlaylistRepo r);

  /// Top-200 → re-weight → flow-filter → argmax.
  /// null only if the library is empty after fallback.
  Future<PickResult?> next(RadioSession session, PlaylistRepo repo);
}
class PickResult {
  final int pickedTrackId;
  final RadioSession nextSession;
  final ScoreBreakdown debug;                 // debug builds only
}
```

```dart
// packages/playlist_engine/lib/flow.dart
class FlowScorer {
  const FlowScorer({
    this.sameArtistWindow = 3, this.historyWindow = 20,
    this.bpmWindow = 15,       this.bpmWindowIntense = 25,
    this.camelotBonusAt1 = 1.15, this.camelotPenaltyAt3 = 0.85,
  });
  /// null → hard reject; otherwise multiplicative bonus in (0, ∞).
  double? scoreOrReject({
    required CandidateMeta candidate,
    required CandidateMeta? previous,
    required RadioSession session,
  });
}
```

```dart
// packages/playlist_engine/lib/camelot.dart
class CamelotKey {
  final int number;  final bool minor;        // 1..12; A = minor
  const CamelotKey(this.number, {required this.minor});
}
class Camelot {
  static CamelotKey? parse(String rawKey);    // "Fm" → 4A; null on unknown
  static int distance(CamelotKey a, CamelotKey b);           // 0..6
  static double compatibilityBonus(CamelotKey a, CamelotKey b);
}
```

```dart
// apps/mobile/lib/widgets/*.dart — all ConsumerWidget, no business logic.
class RadioBadge       extends ConsumerWidget { /* 11pt pill above title; SizedBox.shrink when no session */ }
class SteerChipBar     extends ConsumerWidget { /* FilterChip row inside AnimatedSwitcher keyed on chip-set hash;
                                                   taps dispatch to toggleChip; kChipConflicts auto-clears pairs */ }
class RadioSeedHeader  extends ConsumerWidget { /* "Radio · seeded from '<SeedRef.label>'"; tap → Home */ }
class RadioHomeCard    extends ConsumerWidget { /* PageView of ≤3 RecentSeedsStore entries; tap → new session */ }
```

## 8. Implementation steps

Each step names its files and a one-line pass criterion. Steps 4
and 8 have the most moving parts.

1. **Refresh docs (§4).** Save four ≤5-line API summaries.
   **Pass:** notes exist with concrete spellings.

2. **Create `packages/playlist_engine`.** `pubspec.yaml` with
   `environment: sdk: ^3.4.0`, deps `meta`, `collection`; dev_deps
   `test`, `lints`. Register in `melos.yaml`. **Pass:** `melos
   bootstrap` adds the path dep; `dart analyze` clean.

3. **`PlaylistRepo` + `CandidateMeta` + `KnnHit`.** Pure data;
   imports only `dart:typed_data`. Add `test/fakes/fake_repo.dart`
   (maps + Dart-side L2). **Pass:** `FakeRepo` builds with no
   Flutter / SQLite imports.

4. **`Camelot`.** Map 24 Essentia spellings to the wheel. Distance
   = `min(Δn mod 12, 12 − Δn mod 12) + (minorDiffers ? 1 : 0)`;
   `compatibilityBonus` is a step function. **Pass:**
   `camelot_test.dart` locks the 24-entry parse table + 5×5
   distance spot-check (`4A↔4B = 1`, `4A↔5A = 1`, `4A↔10A = 6`).

5. **`ChipWeights`.** Per chip, a pure kernel
   `(seed, candidate) → double`, aggregated via
   `chipWeight = Π_active (1 + state.weight · (kernel − 1))`.
   Kernels:
   - `happier`/`sadder` = `1 + 0.6·(±(happy − sad))`
   - `calmer`/`moreIntense` = `1 + 0.8·(relaxed·(1−aggr) − 0.5)` and
     its mirror on `(aggr+party)/2`
   - `slower`/`faster` = `1 + 0.5·(±Δbpm/60)`, clamp ±0.5
   - `newer`/`older` = sigmoid of `(±Δyear)/15`
   - `moreLikeThisArtist` = `artistMatch ? 1.5 : 0.9`
   - `differentArtists` = `historyHasArtist(a) ? 0.6 : 1.1`
   **Pass:** `chip_weights_test.dart` asserts per-chip monotonicity
   across a synthetic sweep.

6. **`FlowScorer`.** Hard rejects:
   (a) `candidate.trackId ∈ session.history.last(historyWindow)`;
   (b) all previous `sameArtistWindow` picks share `artistKey`
   with candidate (unless `moreLikeThisArtist` active);
   (c) `|ΔBPM| > bpmWindowIntense` when `moreIntense` active, else
   `> bpmWindow`. Soft bonus: `Camelot.compatibilityBonus` when
   both keys parse; 1.0 otherwise. **Pass:** `flow_test.dart`
   covers each reject path + the bonus path; slice-6 future test
   double-imports `FlowScorer` to prove reuse.

7. **`RadioEngine.from*`.** Track seed = `repo.embeddingOf(id)`;
   album/artist via `repo.meanEmbeddingFor...`. All seeds
   L2-normalized in Dart post-fetch. Build initial `RadioSession`
   with empty chips + history, lookahead = 5. **Pass:** each seed
   variant constructs in <10 ms against `FakeRepo`.

8. **`RadioEngine.next`.** Repo-side vec0 query:
   ```sql
   SELECT te.track_id,
          vec_distance_l2(te.embedding, vec_f32(:seed)) AS d
     FROM track_embeddings te
     JOIN tracks t ON t.id = te.track_id
    WHERE te.embedding MATCH vec_f32(:seed)
      AND te.k = 200 AND t.status = 'ready'
    ORDER BY d;
   ```
   Engine pipeline:
   ```
   final cands = await repo.knnByEmbedding(seed, k: 200);
   final heap  = HeapPriorityQueue<_Scored>(byDescScore);
   for (final c in await _batchMeta(cands)) {
     final sim  = math.exp(-c.l2Distance / 0.5);
     final chip = chipWeights.apply(session, c);
     final flow = flowScorer.scoreOrReject(
         candidate: c, previous: prev, session: session);
     if (flow == null) continue;                  // hard reject
     heap.add(_Scored(c, sim * chip * flow));     // final formula
   }
   if (heap.isEmpty) return _sparseFallback(session, repo);
   final picked = heap.first.meta;
   return PickResult(picked.trackId,
       session.copyAfterPick(picked.trackId, picked.artistKey), ...);
   ```
   **Pass:** `radio_engine_test.dart` seeds 30 fakes, runs `next`
   20 times, asserts zero hard-rule violations (§11 item 2).

9. **`PlaylistRepoImpl`.** In `packages/core`, wraps `CacheDb`:
   `embeddingOf` decodes float32 LE from `track_embeddings`;
   `meanEmbeddingFor{Album,Artist}` fetches all, means, L2-
   normalizes; `knnByEmbedding` runs §8's query. **Pass:**
   integration test against a seeded DB returns the same top-5 IDs
   as a brute-force Dart L2 sweep.

10. **Providers.** `radioSessionProvider`:
    `StateNotifierProvider<RadioSession?>` with
    `startFromTrack/Album/Artist`, `toggleChip`, `stop`.
    `radioModeProvider` = derived bool. `lookaheadProvider` owns
    the ring + append hook. **Pass:** on/off toggles
    `QueueService.radioMode` without PlayNext/Upcoming churn.

11. **`LookaheadManager`.** Subscribes to `currentIndexStream`;
    on advance, pops one from the 5-ring, calls `next(...)`, and
    `ConcatenatingAudioSource.add(AudioSource.uri(Uri.file(path)))`.
    De-dups against `session.history`. **Pass:** manual — 20
    advances, queue never drops below 4 ahead.

12. **Widgets + long-press sheet.** All `ConsumerWidget`.
    `SteerChipBar` enforces `kChipConflicts`.
    `RadioContextSheet.show(context, SeedRef)` bound to track
    rows, album cells, artist cells. **Pass:** badge iff radio
    active; `faster` clears `slower`; long-press header matches.

13. **`RecentSeedsStore`.** JSON list `[{kind, ref, label,
    lastUsedIso}]` in shared prefs, cap 3, LRU. **Pass:** 4 seeds
    leave exactly three entries, oldest evicted.

14. **Run §11.** **Pass:** all items green.

## 9. Alternatives considered

**(a) Let the LLM pick each next track.** Plug slice 6's Ollama /
Cactus pipeline into `RadioEngine.next`. Rejected: (i) latency —
`qwen3:1.7b` is 300–800 ms per prompt on laptop, worse on phone;
appending per advance would stutter or force deeper lookahead;
(ii) Cactus init is slow on first boot and radio must work cold;
(iii) one bad LLM response kills radio while kNN misses degrade
gracefully; (iv) slice 6 owns the LLM risk budget, spendable only
if slice 5 succeeds locally. Reconsider only if radio quality is
qualitatively bad after tuning — then widen the candidate pool
before invoking an LLM.

**(b) Pure random within top-50.** Simplest engine:
`repo.knn(k=50)`, uniform sample. Rejected: loses steering (chips
go cosmetic), loses flow (same-artist clusters surface on prolific
seeds), loses test determinism. It's a reasonable sparse-
neighborhood fallback (§10 risk 1) — kept there — but not the main
path. Reconsider if users say scored picks "feel robotic"; a
hybrid top-5-then-uniform is a 10-line change.

**(c) Fold radio into slice 4.** Slice 4 exposes `knnByEmbedding`
already; minimal radio UI is ~300 LOC. Rejected: slice boundaries
pay for themselves — slice 4's verification is "sidecar ingest
correct," orthogonal to "radio picks feel good." Merging doubles
the verification matrix and couples correctness-and-tuning
milestones. `packages/playlist_engine` belongs to the LLM
trajectory (5→6→8), not the cache trajectory (3→4→9). Reconsider
only if slice 4 lands dramatically under budget and slice 5 is
well-understood — unlikely given chip-formula unknowns.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | Seed with sparse neighborhood: `knn` returns <50 `ready` hits. | `next` checks `cands.length < 50` and calls `repo.libraryWideFallback(limit: 100)` — a cheap random sample across the whole library; chip + flow run over that set. Debug log records the fallback. |
| 2 | Conflicting chips activated simultaneously (`calmer` + `moreIntense`). | UI enforces `kChipConflicts`: tapping one clears the other. Engine asserts `kChipConflicts.entries.none((p) => active.contains(p.key) && active.contains(p.value))` as defense in depth. |
| 3 | User scrubs backward into history. | Scrubbing is a `seek`, not a queue op — `LookaheadManager` keys off `currentIndexStream`. A backward `skipToPrevious` jumps to recent history; the 5-deep tail stays untouched. |
| 4 | Library grew since session started; re-ingest reassigned `tracks.id`. | Each pick records both `trackId` and `audio_sha1`. Between picks, `LookaheadManager` compares tail IDs to current values; on any gap, it invalidates the ring and re-seeds from `session.seed`; history is cleared. |
| 5 | Skip-spam — user skips 5 in a row; naive 20-pick history lets them return quickly. | Per-track `skipWeight` in-session (`Map<int,int>`); `FlowScorer` extends history-window rejection to `20 · skipWeight`, capped at 80. Session-scoped, not persisted. |
| 6 | Album seed where some tracks are `analysis_pending`. | `meanEmbeddingForAlbum` aggregates only `status='ready'` rows; if none, returns null; UI snackbars "No analyzed tracks on this album yet." No silent fall-through. |
| 7 | Artist seed for a one-track artist. | Accept — mean over a single vector is the vector; behaves as `fromTrack`. |
| 8 | Embedding blob length mismatch (future analyzer ships 768 dims). | `PlaylistRepoImpl.embeddingOf` throws `ArgumentError('expected 1280, got $n')`; `RadioEngine.from*` surfaces to UI; long-press action disables. Defends against slice-6 model drift. |
| 9 | `ConcatenatingAudioSource.add` when current index is the last element. | §4 refresh confirms gapless behavior; on mismatch, use `insertAll(index: children.length, ...)` — same effect. |
| 10 | User toggles a chip with no lookahead refill scheduled. | `toggleChip` triggers `LookaheadManager.requeueTail()` — replaces the last `lookahead-1` ring entries with fresh picks. Cheap: ring is 5 deep, query is sub-10 ms on a 5k library. |
| 11 | Camelot parser failing on an unforeseen Essentia key string. | `parse` returns null; `FlowScorer` treats null as "no bonus/penalty, no reject." Silent at worst. A debug-only histogram surfaces unknown keys for future parser additions. |
| 12 | Radio session killed by OEM low-memory purge during backgrounding. | `RecentSeedsStore` persists the seed; the session does not. On cold start the user reseeds via the Home card — one-tap restore. |

## 11. Verification

Run in order. Items 1–6 are the slice-5 acceptance; 7–12 cover the
risk matrix.

1. **Start radio from 'Chrome Pastoral'.** Long-press the row →
   "Start radio from this track". Now Playing shows "RADIO"; Queue
   header reads `Radio · seeded from 'Chrome Pastoral'`; Upcoming
   lists 5 tracks.
2. **Sonic coherence over 20 picks.** Play 20 tracks without
   touching chips. Spot-listen: the sequence feels sonically
   related to the seed. Instrumented: dump
   `ScoreBreakdown.similarity` per pick; mean L2 distance to seed
   stays under `0.8`.
3. **Tempo chip: `faster`.** Over 10 picks BPM trends up: mean of
   picks 1–5 post-toggle ≥ pre-toggle mean + 5 BPM (or, if seed is
   already top-decile, further increase halts — also a pass).
4. **Texture chip: `differentArtists`.** Toggle it. Rate of "same
   artist as a pick in the last 20" drops by ≥50% over 30 picks
   on vs 30 off, in a library with ≥5 tracks per prolific artist.
5. **Lookahead never empties.** Play 30 advances; `AudioPlayer`
   never reports "no source"; tail stays ≥4 (transient dip during
   append OK).
6. **Long-press: album + artist.** Album cell → "Start radio from
   this album"; header reads `Radio · seeded from '<album>'`.
   Artist cell → same with `<artist>`. Each boots in ≤500 ms on
   Pixel 9 Pro Fold.
7. **Conflicting chips.** Tap `calmer` then `moreIntense`: `calmer`
   clears, `moreIntense` activates within one AnimatedSwitcher frame.
8. **Sparse seed.** Move most sidecars aside; start radio from a
   track with <50 neighbors; radio still yields 20 picks; debug log
   shows `libraryWideFallback` engaged.
9. **Skip-spam.** Skip 5 tracks in a row; none of the 5 reappear
   in the next 40 picks.
10. **Library re-ingest mid-session.** Touch a sidecar to trigger
    re-ingest mid-session; the next pick either picks cleanly (IDs
    preserved) or re-seeds quietly (IDs reassigned).
11. **Home Radio card.** Start radio three times from distinct
    seeds; Home shows exactly three cards, newest first; tapping
    the oldest starts a fresh session.
12. **Unit + integration tests.** `melos run test` green for
    `radio_engine_test`, `flow_test`, `camelot_test`,
    `chip_weights_test`, and `playlist_repo_impl_test`; total
    wall-clock <10 s on a laptop.

## 12. Definition of done

- [ ] `packages/playlist_engine` exists with no Flutter / `dart:io`
  / `sqlite3` imports; `dart analyze` clean; `dart test` green.
- [ ] Files in §6 exist; existing-file touches are additive and do
  not regress slice-1 or slice-4 verification suites.
- [ ] `RadioEngine.fromTrack/Album/Artist` each build a session
  with L2-normalized 1280-dim seed; `next` never violates a hard
  flow rule over a 20-pick run.
- [ ] Steer chip vocabulary matches §2 exactly (10 chips, no
  additions); `kChipConflicts` covers all four opposing pairs; UI
  enforces mutual exclusion; TTL decays from 10, reselect resets.
- [ ] `FlowScorer` and `Camelot` callable from outside the engine
  (smoke test in `flow_test.dart` proves API stability for slice 6).
- [ ] `PlaylistRepoImpl` agrees with brute-force Dart L2 sweep on
  top-5 IDs; embedding length mismatch throws `ArgumentError`.
- [ ] `QueueService.radioMode` off: slice-1 semantics unchanged;
  on: picks append to Upcoming, PlayNext preserved at head.
- [ ] "RADIO" badge iff session is non-null; `SteerChipBar`
  animates; Queue header reads `Radio · seeded from '<label>'`;
  Home card shows up to three LRU seeds.
- [ ] Long-press on a track row, album cell, and artist cell each
  expose "Start radio from this ___"; each boots in ≤500 ms on
  Pixel 9 Pro Fold.
- [ ] Sparse-neighborhood fallback to `libraryWideFallback(100)`
  exercised by a unit test; skip-spam extends suppression up to 80
  picks per track, session-scoped.
- [ ] `RecentSeedsStore` keeps at most three seeds, LRU-evicted;
  survives app restart via shared preferences.
- [ ] §4 "Docs to refresh" commands were executed and API-summary
  notes written before any Dart file was touched.
- [ ] No deferred-work sentinels — every unfinished item is scoped
  to a later slice and linked here by number.
