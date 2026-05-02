# Slice 2 kickoff prompt

Paste the entire fenced block below into a fresh Claude Code chat opened
against `/home/sanyo/Projects/music-player`.

**Prerequisites:** slice 1 merged to `master`. `flutter doctor` green.

---

````
I'm executing slice 2 of Prism, a local-first Flutter music player. The repo is at /home/sanyo/Projects/music-player. Slice 1 is merged: Melos workspace, packages/core + packages/playback, AppShell with Settings gear, LibraryScanner, PlaybackService, QueueService, three screens (Tracks/NowPlaying/Queue) all exist.

## Read in order before doing anything else

1. /home/sanyo/Projects/music-player/docs/spec.md — authoritative invariants. Slice 2 must not violate them.
2. /home/sanyo/Projects/music-player/docs/plans/README.md — slice index, dependency DAG, doc-refresh protocol.
3. /home/sanyo/Projects/music-player/docs/plans/slice-02-browse-metadata-random.md — the slice you're executing.

## Confirm slice 1 is actually present

Before doing anything else: confirm `apps/mobile/`, `packages/core/`, `packages/playback/` exist, `melos run test` passes, and `tracksProvider` is exported from `apps/mobile/lib/providers/library_providers.dart`. If any of that is missing, stop and tell the user — slice 2 layers on top of slice 1, not in place of it.

## Before writing ANY Dart

Slice 2 §4 lists six docs to refresh: three external API specs you must WebFetch — MusicBrainz API (musicbrainz.org/doc/MusicBrainz_API), Cover Art Archive (coverartarchive.org), and Last.fm API (last.fm/api) — plus three pub.dev libraries you fetch via `mcp__plugin_context7_context7__resolve-library-id` + `query-docs`: `dio`, `cached_network_image`, `sqflite`. Your training data on the rate-limit headers, error envelope shapes, and current required-header rules will be stale. Write a ≤5-line "API summary" per source; keep in conversation, do not commit.

## Execution

Follow slice 2 §8 step-by-step. The file layout in §6 is fixed; the `packages/metadata` package is new this slice. Interface signatures in §7 are the contract. Stop at each step's pass criterion.

## Hard constraints

- **MusicBrainz: 1 req/sec, single global Pacer.** Hard-coded budget. CAA and Last.fm have separate informal budgets but no Pacer.
- **Required User-Agent header on every MusicBrainz request:** `Prism/0.x ( <user contact email> )`. The contact email comes from a new Settings row this slice adds — use it as a hard precondition. For development, the user's email is `sanays.mail@gmail.com`.
- **Read-only HTTP only.** No MusicBrainz write-back. No acoustid fingerprinting. No local mirror. No cover-art override (that's slice 4).
- **No mood chips, no LLM, no Random tab seeded ordering beyond a per-section seed.** Mood chips ship in slice 4; LLM in slice 6; Random uses client-side `Random` only — no `ORDER BY RANDOM()`.
- **Backfill is post-scan, single-track, off the UI thread.** Patch stream nudges the in-memory `Track` set; browse rows update in place.
- `packages/metadata` is pure Dart (no Flutter imports). Same discipline as `packages/core`.

## When done

Run §11 verification + check §12 DoD. Report green/red/blocked. The known manual verification step is the "delete tags from a test FLAC, confirm MusicBrainz backfill repopulates them" check.
````
