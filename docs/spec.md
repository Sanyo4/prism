# Local-First Music Player with Sonic Analysis + On-Device LLM Vibe Playlists

> Status: **thought-experiment spec** — buildable, decomposed into executable slices.
> Target build mode: per-slice "vibe coding" with live doc refresh at each slice start.

---

## Context

The user's current setup:

- FLAC (often 24-bit hi-res) library on Linux laptop.
- Library synced to Android phone via **Syncthing** (bi-directional, automatic).
- Today: **Tauon Music Box** on laptop, **Symphonium** on Android.
- Home playback currently goes to a **Sony STR-DN1080** receiver via Chromecast, which caps / downsamples hi-res — the user wants true lossless.

The goal: a single Flutter app (Android + Linux desktop) that replaces both current players and adds a local-LLM "vibe → one-shot playlist" feature backed by sonic analysis of the library. Fully offline on both ends. No music server.

Core insight that drives the architecture: **Syncthing already solves sync.** Analysis data lives as tiny sidecar files next to audio files inside the already-synced folder — no shared database, no server, no write conflicts, no custom sync logic.

---

## Scope

**Included**
- Gapless playback, ReplayGain (track + album), lockscreen/notification controls, OS-native Bluetooth codec handling.
- Library scan of a single configured folder (recursive).
- Browse: Album / Artist / Genre / Vibe.
- Desktop-side sonic analysis via **Essentia** → `.sonic.json` sidecar next to each audio file.
- Local SQLite cache built by scanning sidecars (source of truth is the sidecar files).
- Online metadata fallback: MusicBrainz + Cover Art Archive + Last.fm.
- Vibe-to-playlist engine:
  - Desktop: **Ollama** + Qwen3-1.7B-Instruct (Ollama tag `qwen3:1.7b`).
  - Android: **Cactus** + Qwen3-1.7B-Instruct INT4.
- DLNA / UPnP AVTransport "push" to the Sony STR-DN1080 (lossless, hi-res preserved, no Chromecast).
- Apple Music-inspired visual style (generous whitespace, hero album art, adaptive palette).

**Explicitly excluded**
- Equalizer / DSP beyond ReplayGain.
- Lyrics, scrobbling, Android Auto.
- LAN streaming, embedded music server.
- Spotify / Tidal / cloud integrations.

---

## Architecture

```
Laptop (Linux)                                   Phone (Android)
┌──────────────────────────┐                    ┌──────────────────────────┐
│ Flutter app              │                    │ Flutter app              │
│  - playback              │                    │  - playback              │
│  - browse UI             │                    │  - browse UI             │
│  - Ollama vibe→playlist  │                    │  - Cactus vibe→playlist  │
│  - DLNA push to Sony     │                    │                          │
│  - ┌──────────────────┐  │                    │  - ┌──────────────────┐  │
│    │ SQLite cache     │  │                    │    │ SQLite cache     │  │
│    │ (rebuilt on scan)│  │                    │    │ (rebuilt on scan)│  │
│    └──────────────────┘  │                    │    └──────────────────┘  │
│                          │                    │                          │
│ Python indexer (CLI)     │                    │                          │
│  - Essentia analysis     │                    │                          │
│  - writes .sonic.json    │                    │                          │
└─────────────┬────────────┘                    └────────────┬─────────────┘
              │                                              │
              │   Syncthing folder (shared source of truth)  │
              ▼                                              ▼
       ┌─────────────────────────────────────────────────────────┐
       │  /Music/                                                │
       │    Artist/Album/01 - Track.flac                         │
       │    Artist/Album/01 - Track.sonic.json   ← analysis      │
       │    Artist/Album/cover.jpg                               │
       │  ...                                                    │
       └─────────────────────────────────────────────────────────┘
```

**Invariants**
- Source of truth = audio files + `.sonic.json` sidecars in the Syncthing folder.
- Each device builds its own disposable SQLite cache by scanning sidecars on change.
- The Python indexer runs **only** on the laptop. Phone is a read-only consumer.
- No shared DB, no server, no runtime network dependency (DLNA is LAN-only, at-home use).

---

## Stack & authoritative doc sources

At the start of **every slice**, fetch the current docs for that slice's libraries. Do not rely on training data.

| Concern | Library / Tool | Doc source to refresh at build time |
|---|---|---|
| UI | Flutter (stable) | `api.flutter.dev`, `flutter.dev` via WebFetch |
| Playback | `just_audio` | Context7 MCP (`query-docs`), pub.dev |
| Session / notifications | `audio_service` | Context7, pub.dev |
| Tag reading | `audiotags` | Context7, pub.dev |
| DB | `sqflite` + `sqlite3_flutter_libs` | Context7 |
| Vector search | `sqlite-vec` via FFI | `github.com/asg017/sqlite-vec` README + quickstart |
| Palette | `palette_generator` | Context7 |
| HTTP | `dio` | Context7 |
| Desktop LLM | Ollama daemon | `github.com/ollama/ollama/blob/main/docs/api.md` |
| Android LLM | Cactus | `github.com/cactus-compute/cactus` README + examples + Flutter binding |
| LLM model | Qwen3-1.7B-Instruct (Ollama `qwen3:1.7b` on desktop, Cactus INT4 on Android) | HuggingFace model card |
| Sonic analysis | Essentia + musicnn + effnet-discogs | `essentia.upf.edu/documentation.html`, model cards on `essentia.upf.edu/models.html` |
| Metadata | MusicBrainz | `musicbrainz.org/doc/MusicBrainz_API` |
| Art | Cover Art Archive | `coverartarchive.org` |
| Artist bios/tags | Last.fm | `last.fm/api` |
| Cast protocol | UPnP AVTransport v1 | UPnP-AV service spec (PDF from `upnp.org`) |
| Discovery | SSDP | RFC 5999 draft + reference implementations |
| Receiver specifics | Sony STR-DN1080 DLNA capabilities | Sony help guide for the model |

---

## Sidecar format — `<track>.sonic.json`

```json
{
  "schema_version": 1,
  "analyzer": "essentia-2.1-beta6-dev",
  "analyzer_models": ["musicnn-msd-2", "discogs-effnet-bs64-1"],
  "audio_sha1": "ab12…",
  "duration_sec": 234.5,
  "sample_rate": 96000,
  "bit_depth": 24,
  "bpm": 118.4,
  "bpm_confidence": 0.88,
  "key": "Fm",
  "key_confidence": 0.74,
  "loudness_lufs": -14.2,
  "replaygain_track_db": 3.1,
  "replaygain_album_db": 3.4,
  "spectral_centroid_mean": 1832.0,
  "danceability": 0.61,
  "mood": {
    "happy": 0.22, "sad": 0.67, "aggressive": 0.08,
    "relaxed": 0.71, "party": 0.14
  },
  "genre_top3": [["indie rock", 0.41], ["alternative", 0.22], ["shoegaze", 0.14]],
  "voice_instrumental": 0.88,
  "embedding_model": "discogs-effnet-bs64-1",
  "embedding": [0.013, -0.221, "...", 0.074]
}
```

**Versioning rules**
- Bump `schema_version` only on breaking reader changes.
- Add fields freely; readers must ignore unknowns.
- Indexer re-analyzes a track when: (a) `audio_sha1` mismatches, (b) `analyzer_models` differ, or (c) `schema_version` is behind current.

---

## SQLite schema (each device rebuilds from sidecars)

```sql
CREATE TABLE tracks (
  id                  INTEGER PRIMARY KEY,
  path                TEXT UNIQUE NOT NULL,
  audio_sha1          TEXT NOT NULL,
  sidecar_path        TEXT,
  sidecar_mtime       INTEGER,

  -- tag metadata
  title               TEXT,
  artist              TEXT,
  album_artist        TEXT,
  album               TEXT,
  track_no            INTEGER,
  disc_no             INTEGER,
  year                INTEGER,
  genre               TEXT,
  duration_sec        REAL,

  -- sonic analysis (scalar)
  bpm                 REAL,
  key                 TEXT,
  loudness_lufs       REAL,
  replaygain_track_db REAL,
  replaygain_album_db REAL,
  danceability        REAL,
  voice_instrumental  REAL,

  -- mood vector (flat columns for fast filtering)
  mood_happy          REAL,
  mood_sad            REAL,
  mood_aggressive     REAL,
  mood_relaxed        REAL,
  mood_party          REAL,

  added_at            INTEGER
);
CREATE INDEX tracks_artist ON tracks(artist);
CREATE INDEX tracks_album  ON tracks(album);
CREATE INDEX tracks_genre  ON tracks(genre);

CREATE VIRTUAL TABLE track_embeddings USING vec0(
  track_id  INTEGER PRIMARY KEY,
  embedding FLOAT[1280]
);
```

---

## Project layout (to be created)

```
music_player/
├── apps/
│   ├── mobile/                        # Flutter app, targets Android + Linux desktop
│   │   ├── lib/main.dart
│   │   ├── lib/app.dart
│   │   └── pubspec.yaml
│   └── indexer/                       # Python CLI, desktop-only
│       ├── indexer/__main__.py
│       ├── indexer/essentia_runner.py
│       ├── indexer/sidecar_writer.py
│       └── pyproject.toml
├── packages/                          # Dart packages (monorepo via melos or path deps)
│   ├── core/                          # models, sidecar reader, DB schema
│   ├── playback/                      # just_audio wrapper + gapless + ReplayGain
│   ├── metadata/                      # MusicBrainz + CAA + Last.fm fetchers
│   ├── playlist_engine/               # vibe→intent→kNN→flow scoring (platform-agnostic)
│   ├── llm_desktop/                   # Ollama REST client
│   ├── llm_mobile/                    # Cactus integration
│   └── dlna/                          # SSDP + SOAP client + embedded HTTP server
└── docs/
    └── notes/
```

---

## Playlist engine — the hybrid LLM+kNN flow

1. **User types a vibe.** Example: *"melancholy late-night drive, 90s lean, builds over time, ~45 min."*
2. **LLM → structured intent** (JSON):
   ```json
   {
     "mood_targets": {"sad": ">=0.5", "relaxed": ">=0.4", "aggressive": "<=0.3"},
     "bpm_range": [70, 110],
     "era": [1988, 1999],
     "energy_arc": "build",
     "duration_minutes": 45,
     "seed_tracks": [],
     "narrative": "late-night drive, introspective open, lift mid-set"
   }
   ```
3. **Candidate pool** via SQL filter on mood / BPM / era.
4. **Ranking** = weighted similarity on embedding centroid of intent + mood-target distance.
5. **Flow scoring** — pick an ordering that:
   - follows the requested energy arc (monotone-build / wave / flat),
   - keeps adjacent tracks within ±8 BPM or half/double-time,
   - keeps adjacent keys within Camelot-wheel distance ≤ 1,
   - avoids >2 tracks by the same artist in a 10-track window.
6. **LLM final narrative pass** — given the ordered candidate list + narrative, LLM may swap 1–3 tracks it thinks break the arc, then produces a one-line playlist blurb.

Engine is a pure function on `(intent, track_pool) → ordered track_ids`. Identical on desktop and mobile; only the LLM backend differs.

---

## Build slices (order, each independently runnable)

1. **Scaffold + scan + play.** Flutter monorepo, empty UI, `audiotags` scan of a chosen folder, `just_audio` plays a selected track. Lockscreen/notification controls via `audio_service`. ReplayGain applied.
2. **Browse UI + online metadata.** Albums / Artists / Genres views. MusicBrainz + CAA backfill for missing fields/art, cached locally.
3. **Essentia indexer.** Python CLI: `indexer scan <path>` — writes `.sonic.json` sidecars. Handles hash-based skip & resumable runs.
4. **Sidecar ingest + Vibe browse.** Flutter scans sidecars, builds SQLite + `vec0` embedding table. Browse-by-vibe view (pre-defined moods from classifier output).
5. **Desktop LLM playlists.** Ollama client + playlist engine. Natural-language vibe prompt → 15-track playlist playable from the UI.
6. **Apple Music polish.** Theming pass, hero transitions, adaptive palette from album art, typography.
7. **Android Cactus integration.** Ship Qwen3-1.7B INT4, same playlist engine backend swap. Verify offline on phone.
8. **DLNA push to Sony.** SSDP discovery → receiver list. Embedded HTTP server serves selected file. SOAP `SetAVTransportURI` + `Play`. Transport state polled for UI. Test with 24/96 FLAC; front panel should report "96 kHz / 24 bit".

---

## Verification per slice

| Slice | Verification |
|---|---|
| 1 | Play 10 tracks; gapless between a known album-transition pair; lockscreen shows art + controls; ReplayGain: quiet track and loud track within ~2 LUFS of each other. |
| 2 | Artist/album/genre views match library. Delete all tags from one test track; MusicBrainz backfill re-populates them. |
| 3 | Run indexer on a 20-track folder → 20 sidecars. Re-run → zero re-analyzes. Touch one file → one re-analyze. |
| 4 | "Vibe: melancholy" returns plausibly sad tracks. kNN from a known reference track returns plausibly similar tracks. |
| 5 | Natural-language vibe on desktop produces a coherent 15-track playlist (spot-check). Playlist plays end-to-end. |
| 6 | Side-by-side vs Apple Music screenshots on album detail, now-playing, and browse. |
| 7 | Same natural-language flow as slice 5, but on phone, in airplane mode. Playlist generated fully on-device. |
| 8 | 24/96 FLAC pushed to STR-DN1080. Receiver reports matching rate/depth on front panel. Pause/resume/skip work from app. |

---

## Doc refresh protocol (at start of each slice)

Before writing any code for a slice, the model will:

1. Identify every library/API/protocol touched in the slice.
2. Run `mcp__plugin_context7_context7__resolve-library-id` then `query-docs` for each pub.dev / npm / PyPI package.
3. WebFetch canonical docs for anything Context7 lacks (Cactus README, Essentia, UPnP spec, Sony manual).
4. Write a short "docs checked, API summary" preamble before producing code, so any drift between training-data memory and current docs is caught before it hits the keyboard.

---

## Honest limits on "vibe coding" this

Per-slice, I can one-shot with high confidence on:
- Scaffold, scan, DB, sidecar reader, playlist engine (pure logic), metadata fetchers, browse UI, theming.

Per-slice, I expect **one iteration of "ran it, hit X, fix"** on:
- `just_audio` ReplayGain wiring (platform-specific),
- Essentia model paths / model download,
- Cactus init on Android (evolving API),
- DLNA push to Sony (firmware quirks only visible at runtime).

Per-slice, fully subjective / needs tuning:
- Vibe-prompt quality — prompt iteration based on how the playlists feel.

Total realistic execution: **~8 focused sessions**, each ~1 slice, with you testing between. That is the fastest path to a working app that isn't full of silent bugs.

---

## Critical files (to be created, not modified — greenfield)

See **Project layout** above. No existing files to modify.
