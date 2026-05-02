# Slice 5 — doc-refresh notes (per §4)

Track A scope only — pure-Dart engine + repo adapter. just_audio /
AnimatedList / AnimatedSwitcher are Track B's concern; not refreshed
here.

## sqlite-vec / `vec0` — kNN query shape (confirmed against committed v0.1.9)

- Bind seed as little-endian IEEE-754 float32 `Uint8List` (5120 bytes
  for 1280 dims). Slice 4's helper `embeddingBytes(...)` already does
  this; `PlaylistRepoImpl.knnByEmbedding` reuses the same encoding.
- Canonical kNN: `WHERE embedding MATCH ? AND k = ? ORDER BY distance`
  — slice 4's `runKnnByEmbedding` uses this exact shape. `k = ?` is
  authoritative; do not also pass `LIMIT` or the planner widens.
- vec0 returns a synthetic `distance` column (L2). `LIMIT` truncates
  the post-MATCH result set; `k` controls how many neighbours vec0
  itself walks. Slice 5 stays on `k`-only.
- vec0 does **not** honour `INSERT OR REPLACE` — slice-4 `upsertEmbedding`
  uses delete-then-insert. Track A only reads embeddings; not relevant
  to writes here, but documented for repo-adapter test seeding.
- `vec_f32(?)` JSON helper exists; we don't use it — raw 5120-byte
  blob path is faster and matches slice 4's tests.

## `collection` — `HeapPriorityQueue<T>` (per query-docs / Context7)

- Constructor: `HeapPriorityQueue<T>(int Function(T a, T b) compare)`
  — comparator returns negative when `a` ranks first.
- `.add(T)` is O(log n); `.first` is O(1) (peek, not pop).
- `.removeFirst()` pops; `.length`, `.isEmpty` standard.
- For "argmax score over 200 candidates", comparator is
  `(a, b) => b.score.compareTo(a.score)` so `.first` is the best.
- We do not need a stable-tie order; vec0's distance is dense enough
  that exact ties are vanishingly rare and `.first` is acceptable.

## `meta` — annotations only

- `@immutable` on value classes documents intent; analyzer enforces
  final-fields. Used on `RadioSession`, `ChipState`, `KnnHit`,
  `CandidateMeta`, `PickResult`, `ScoreBreakdown`.
- No runtime cost; pure Dart.

## Dart `dart:math` — `exp`, `min`, `Random`

- `math.exp(-d / 0.5)` for the L2-to-similarity map (§5).
- `math.Random` for the library-wide fallback's tiny shuffle when the
  repo returns ≥ `limit`. Tests pass a seeded `Random` for determinism.

## Track B — UI / radio plumbing scratch notes

### `just_audio` — `ConcatenatingAudioSource.add` / `insertAll` (verified 0.10.5)

- `ConcatenatingAudioSource` exposes `add(AudioSource)` and
  `insertAll(int index, List<AudioSource>)`; both mutate while the
  player is `playing` and gapless playback is preserved when the new
  entry is appended to the tail (current source plays through, the
  appended source's first sample arrives without a glitch).
- The `currentIndex` is stable across `add` (the playing source's
  index does not shift; appended children land at `children.length`).
- For `LookaheadManager.appendForRadio`, calling `add` from a stream
  listener is safe — just_audio queues the mutation on its own MS event
  loop. No `await` required to avoid stutter.

### Flutter `AnimatedSwitcher` (api.flutter.dev confirmed)

- Default `duration: 250 ms` fade+slide via `_FadeTransition` is what
  ships when no `transitionBuilder` is provided.
- Key on the active-chip set hash (e.g. `Object.hashAll(activeChips)`)
  so the `AnimatedSwitcher` swaps children whenever the chip set
  changes — toggling `faster` after `slower` fires the animation
  exactly once per state change.
- Children must each carry a unique `Key` for the switch to fire;
  use a `ValueKey(setHash)`.

### `shared_preferences` — JSON list under one key (3.x verified)

- `SharedPreferences.getInstance()` is async-but-cached; subsequent
  calls return the same singleton. Safe to call inside a `Notifier`
  build-future without lock contention.
- `setStringList(String key, List<String>)` and `getStringList(...)`
  exist; we serialize the recent-seeds list to JSON via
  `jsonEncode/jsonDecode` and store it under one key
  (`prism.radio.recent_seeds`). Cap at 3 entries, LRU on tail-evict.
- Survives app restart; cleared only on explicit
  `SharedPreferences.clear()` (we never call this).
