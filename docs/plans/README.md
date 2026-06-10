# Prism — Slice plans

Each slice below is a single session. Read the file, refresh docs as listed
in its "Docs to refresh" section, build, verify. Don't skip verification.
`docs/spec.md` is the authoritative invariant layer — slice plans link to
it but do not restate it.

## Slices

| # | File | Purpose | Depends on | Status |
|---|---|---|---|---|
| 1 | [slice-01-scaffold-scan-play-queue.md](./slice-01-scaffold-scan-play-queue.md) | Melos monorepo, scan, playback, queue, `AppShell` + Settings gear | — | todo |
| 2 | [slice-02-browse-metadata-random.md](./slice-02-browse-metadata-random.md) | Album/Artist/Genre browse, MusicBrainz/CAA/Last.fm backfill, Random tab | 1 | todo |
| 3 | [slice-03-essentia-indexer.md](./slice-03-essentia-indexer.md) | Linux-only Python CLI writing `.sonic.json` sidecars | — | todo |
| 4 | [slice-04-sidecar-ingest-moods-vibe.md](./slice-04-sidecar-ingest-moods-vibe.md) | Sidecar reader, SQLite + `vec0`, mood home row, vibe browse | 1, 3 | todo |
| 5 | [slice-05-infinite-radio.md](./slice-05-infinite-radio.md) | Seed-kNN radio + steer chips; introduces `packages/playlist_engine` | 4 | todo |
| 6 | [slice-06-desktop-llm-playlists.md](./slice-06-desktop-llm-playlists.md) | Ollama + Qwen3-1.7B, 12-track `PlaylistEngine` | 5 | todo |
| 7 | [slice-07-apple-music-polish.md](./slice-07-apple-music-polish.md) | Typography, heroes, adaptive palette + 5 fallback presets | 2 | todo |
| 8 | [slice-08-android-cactus-llm.md](./slice-08-android-cactus-llm.md) | Cactus Flutter SDK + Qwen3-1.7B INT4; `LlmBackend` parity | 6 | todo |
| 9 | [slice-09-cast-and-dlna.md](./slice-09-cast-and-dlna.md) | DLNA push + Android-only Chromecast fallback | 1 | todo |

## Dependency DAG

```
     ┌──► 2 ──► 7             (7 = polish; can run any time after 2)
     │
 1 ──┤           ┌──► 6 ──► 8 (8 brings Android LLM to parity with 6)
     │           │
     │    3 ──► 4 ──► 5 ──┤
     │                    └────  (5 unblocks 6; radio works without LLM)
     └───────────────────► 9   (9 = cast/DLNA; needs 1 only)
```

Slice 3 (Python indexer) is independent of the Flutter tree — can be built
in parallel with slice 1 on a separate branch.

## Invariants (from `docs/spec.md`)

Slice plans must respect these. If a plan needs to change one, update the
spec first.

- **Source of truth:** audio files + `.sonic.json` sidecars in the Syncthing
  folder. SQLite is a disposable per-device derived cache.
- **Indexer is Linux-only.** Essentia + models never run on Android. The
  phone reads sidecars; it does not analyze audio.
- **Sync is passive.** The app does not invoke Syncthing; Syncthing runs
  independently and replicates the whole music folder (both `.flac` and
  `.sonic.json`) between devices.
- **Sidecar schema version 1.** Sidecars embed `audio_sha1`,
  `analyzer_models`, and `schema_version`. Any mismatch invalidates the
  sidecar — the track is marked `analysis_pending` and excluded from
  mood/radio surfaces until the indexer refreshes it.
- **DLNA is LAN-only.** No cloud, no relay. Hi-res path = DLNA to
  STR-DN1080. Chromecast is lossy and Android-only.
- **LLM is Qwen3-1.7B-Instruct.** Two engines (Ollama on Linux, Cactus on
  Android). Identical prompts. Same `LlmBackend` Dart interface.
- **Playlist length 12 tracks.** Radio is "infinite" (lookahead 5, refills
  forever).
- **Settings reachable from every top-level screen** via a gear icon in the
  top-right of `AppShell`.

## Doc refresh protocol

Before writing code for a slice, refresh every library named in its "Docs
to refresh" section:

1. For pub.dev / PyPI packages: run
   `mcp__plugin_context7_context7__resolve-library-id` then `query-docs`
   with the exact topics listed in the slice.
2. For specs, vendor documentation, or anything Context7 lacks: `WebFetch`
   the exact URL listed.
3. Write a one-paragraph "API summary" capturing what changed vs your
   training data. Save it in a scratch file during the session; discard
   afterwards.
4. Only then start implementation. Your memory of any of these APIs is
   likely wrong.

## Naming conventions

- Packages: `packages/<name>` — one feature per package.
- Dart files: `snake_case.dart`.
- Dart classes: `UpperCamelCase`. Interface prefix `Abstract` reserved for
  `abstract class`.
- SQL tables: `snake_case`, singular if a 1:1 record (e.g. `track`), plural
  if it's clearly a set (e.g. `metadata_cache`).
- Python: standard PEP 8. CLI entry is `prism-indexer`.

## Tech stack (locked across slices)

- **Flutter** stable channel, Dart 3+.
- **State:** Riverpod (picked in slice 1, locked for the whole app).
- **Audio:** `just_audio` + `audio_service`.
- **Tags:** `audio_metadata_reader` (pure Dart; exposes ReplayGain fields + raw custom-tag map, so it satisfies the "only tag-embedded values in slice 1" invariant that `audiotags` 1.4.5 cannot).
- **DB:** `sqflite` + `sqlite3_flutter_libs` + `sqlite-vec` (FFI).
- **HTTP:** `dio`.
- **Images:** `cached_network_image`.
- **Theme:** `palette_generator` + Material 3 `ThemeExtension`.
- **Monorepo:** Melos.
- **Indexer:** Python 3.11+, Essentia, `click`.
- **LLM (desktop):** Ollama REST, `qwen3:1.7b`.
- **LLM (Android):** Cactus Flutter SDK, `Qwen/Qwen3-1.7B` INT4.
- **Cast:** `packages/cast` (DLNA everywhere + Google Cast on Android).

## See also

- [`docs/spec.md`](../spec.md) — authoritative architecture, sidecar format,
  SQLite DDL.
