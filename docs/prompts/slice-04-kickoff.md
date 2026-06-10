# Slice 4 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slices 1 + 3 merged to `main`. You'll also need real
`.sonic.json` files on disk — run `prism-indexer scan ~/Music` (slice 3's
CLI) on at least a few hundred tracks before starting verification.

---

````
I'm executing slice 4 of Prism: sidecar ingest + SQLite (with `vec0` virtual table) + the 5-mood Home row + Vibe browse. The repo is at /home/sanyo/Projects/music-player. Slices 1 and 3 are merged.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — the SQLite DDL and the sidecar schema are locked here. Slice 4's parser must accept exactly the format slice 3 emits.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index, "phone never re-analyzes" + "sidecar is source of truth" invariants.
3. /home/sanyo/Projects/music-player/docs/plans/slice-04-sidecar-ingest-moods-vibe.md — the slice you're executing.

## Confirm prerequisites are actually present

Before writing code:
- `apps/indexer/` exists and `prism-indexer scan ~/Music` has produced at least a few hundred `.sonic.json` files in the user's library. If not, stop — slice 4's verification (mood row populates, kNN returns plausible neighbours) needs real analyzed data.
- Slice 1 artifacts present: `LibraryScanner`, `Track`, `tracksProvider`, `PlaybackService` all exist and tests pass.

## Before writing ANY Dart

Slice 4 §4 lists docs to refresh: sqflite, sqlite3_flutter_libs, sqlite-vec (github.com/asg017/sqlite-vec quickstart + Dart binding), and any updates to flutter_riverpod since slice 1. The `vec0` extension load mechanic shifted between sqlite-vec releases — confirm whether to use `db.rawQuery("SELECT load_extension(...)")` vs the bundled-library approach in `sqlite3_flutter_libs`. Write a ≤5-line "API summary" per library; keep in conversation.

## Execution

Follow slice 4 §8 step-by-step. The file layout in §6 is fixed. Stop at each step's pass criterion.

## Hard constraints

- **Sidecar is source of truth, SQLite is a disposable cache.** Drop + rebuild from sidecars on any schema bump. Never write back to the sidecar file from Flutter.
- **Phone never re-analyzes audio.** Read-only consumer of sidecars Syncthing replicates. No Essentia, no model files, no TF on Android.
- **Strict sidecar validation.** Reject on `audio_sha1` mismatch, `schema_version` newer or older than CURRENT, or disjoint `analyzer_models`. Such tracks become `status='analysis_pending'` — still playable, but excluded from mood chips, Vibe browse, and (slice 5's) kNN seeds.
- **Mood row order is locked: Happy / Sad / Chill / Energetic / Focus.** Do not reorder. Mapping from classifier outputs (`happy/sad/aggressive/relaxed/party`) to display moods is in §7 — follow it exactly.
- **Measured ReplayGain replaces tag RG when row is `ready`.** PlaybackService precedence: cache `replaygain_*_db` > tag value > 0 dB.
- **No file watcher in slice 4.** Re-scan button is canonical (file-watcher is §10 risk 11, deferred).
- **No LLM, no radio UI, no album-level RG re-grouping, no adaptive palette.** All later slices.

## When done

Run §11 verification + check §12 DoD. Key external truth: tap the "Sad" mood chip on Home and inspect — top results should be subjectively sad tracks the indexer scored high on `mood_sad`. kNN from a known reference track returns plausibly similar tracks.
````
