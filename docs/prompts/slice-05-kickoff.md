# Slice 5 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slice 4 merged to `main`. CacheDb populated with embeddings
from real analyzed tracks (run the indexer + a Re-scan first).

---

````
I'm executing slice 5 of Prism: Infinite Radio. The repo is at /home/sanyo/Projects/music-player. Slices 1, 3, and 4 are merged. CacheDb is populated with track embeddings.

This slice introduces `packages/playlist_engine` — the FIRST platform-agnostic pure-Dart package in the tree. Discipline matters: zero Flutter, zero `dart:io`, zero `sqlite3` imports inside this package. It talks to the world through one `PlaylistRepo` port. That discipline is what lets slice 6's LLM-driven `PlaylistEngine` drop in beside `RadioEngine` later without refactoring.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — playlist engine semantics + Camelot wheel rules + LLM/non-LLM separation.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index, "playlist length 12, radio infinite" invariant.
3. /home/sanyo/Projects/music-player/docs/plans/slice-05-infinite-radio.md — the slice you're executing.

## Before writing ANY Dart

Slice 5 §4 lists docs to refresh: meta + collection (the only deps), Float32List manipulation patterns, and a re-skim of slice 4's CacheDb API to lock the `PlaylistRepo` port shape. Also re-read slice 6's plan section on `LlmBackend` so this slice's `FlowScorer` and `Camelot` come out reusable. Write ≤5-line summaries; keep in conversation.

## Execution

Follow slice 5 §8 step-by-step. File layout in §6 is fixed. Stop at each pass criterion.

## Hard constraints

- **packages/playlist_engine is pure Dart.** No Flutter, no dart:io, no sqlite3, no path_provider. Deps: `meta`, `collection`. Dev deps: `test`, `lints`. The single seam to the outside world is `abstract class PlaylistRepo` — implemented by an adapter in `packages/core` that wraps CacheDb.
- **NO LLM in this slice.** Radio must work cold, on first launch, in airplane mode, with no model files. Slice 6 adds the LLM backend; do not anticipate it here.
- **Steer chip vocabulary is locked at 10:** happier, sadder, calmer, moreIntense, slower, faster, newer, older, moreLikeThisArtist, differentArtists. Do not add, rename, or reorder. Per-chip linear TTL decay over 10 picks; reselect resets to 10. UI enforces mutual exclusion on each opposing pair.
- **FlowScorer rules are hard:** no same-artist within 3 picks; |ΔBPM| ≤ 15 (widens to 25 only when `moreIntense` is active); hard de-dup against last 20 history ids in session. Camelot distance ≤ 1 is a soft bonus, ≥ 3 a penalty.
- **FlowScorer + Camelot must be reusable by slice 6 unmodified.** No radio-specific state inside them. Pure functions. `flow_test.dart` imports them from outside the radio call site to prove API stability.
- **Lookahead 5 tracks pre-picked.** Player never stalls at the tail.
- **No persistent sessions across app restart.** `RecentSeedsStore` is the one-tap restore from the Home card.
- **No server-side recommenders.** No Last.fm `track.getSimilar`, no Spotify Radio, no MusicBrainz lookups for sonic similarity. Pure local kNN.

## When done

Run §11 verification + check §12 DoD. Key external truth: long-press a track → "Start radio from this track" → 5 tracks pre-loaded → playback advances seamlessly forever, with steer chips visibly shifting the upcoming queue when toggled.
````
