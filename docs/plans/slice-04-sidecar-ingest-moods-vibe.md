# Slice 4 — Sidecar ingest, SQLite + `vec0`, mood home row, vibe browse

## 1. Context

Slice 4 is where the Flutter app — phone and desktop both — starts
actually *using* the sonic analysis slice 3's Python indexer
produces. Until now, playback and browse are tag-only; `.sonic.json`
files are inert. This slice introduces `SidecarReader` and `CacheDb`
in `packages/core`, wires `packages/playback` to prefer measured
ReplayGain from the cache over tag-embedded values, and exposes two
new UI surfaces: a **5-chip Mood row on Home** and a **Vibe browse**
screen in Library. The store is a single SQLite DB per device,
augmented with `sqlite-vec`'s `vec0` virtual table for embedding
kNN. The database is a disposable derived cache — the sidecar is
the source of truth, as locked by `docs/spec.md`.

The shape of this slice is the three-way handshake between the
Syncthing folder, the read-only sidecar contract, and the phone. The
phone never re-analyzes audio; it trusts whatever sidecar Syncthing
replicates. Ingest is idempotent replay of what is on disk, with
validation of `audio_sha1`, `schema_version`, and `analyzer_models`
before a row is usable. Mismatches mark the track `analysis_pending`
— playback still works, but the track is excluded from mood chips,
Vibe browse, and (slice 5) kNN seeds until the desktop indexer
refreshes and Syncthing propagates. Assumes slices 1 and 3 done.

## 2. Goals / Non-goals

**Goals**

- `packages/core/SidecarReader`: parse `<track>.sonic.json` into a
  strict `Sidecar` model with `schema_version` validation + unknown-
  field tolerance.
- `packages/core/CacheDb`: `sqflite` wrapper over a single per-device
  DB file; linear `Migrations` starting at v1; `vec0` virtual table
  loaded at open-time via `sqlite3.enableLoadExtension`.
- Ingest flow triggered by slice 1's `LibraryScanner` or a manual
  Re-scan button: for each audio file, locate the sibling sidecar,
  verify `audio_sha1` stability + `schema_version ==
  CURRENT_SCHEMA_VERSION`; on `mtime` change, parse + upsert row +
  embedding.
- Reconcile: rows whose `path` didn't appear in the scan flip to
  `status='missing_audio'`.
- `packages/playback` prefers measured `replaygain_*_db` from
  `CacheDb` over tag values when row is `ready`; tags are fallback.
- **Mood home row** (locked order): **Happy / Sad / Chill /
  Energetic / Focus**. Tap → filtered list sorted by
  `mood_confidence * log(1 + play_count) * recency_factor`.
- **Vibe browse** in Library: classifier-native chips
  `happy / sad / aggressive / relaxed / party` + tempo band
  (`calm <90 BPM`, `mid 90–120`, `hot >120`).
- Sidecar staleness enforced (mismatched `audio_sha1`, older
  `schema_version`, disjoint `analyzer_models` → `analysis_pending`).

**Non-goals**

- kNN radio UI — slice 5 consumes `knnByEmbedding`; screen lives there.
- LLM-driven playlists (slices 6, 8).
- On-device Essentia / any re-analysis on the phone.
- Invoking Syncthing or parsing its state — app only reads the FS.
- Album-level RG re-grouping (later slice).
- Adaptive palette / hero transitions (slice 7).
- Live file-watcher is a stretch (§10 risk 11); Re-scan is canonical.

## 3. Dependencies

Depends on: 1, 3
Unblocks: 5

Slice 1 contributes `Track`, `LibraryScanner`, the Riverpod graph,
and `PlaybackService`. Slice 3 contributes the on-disk sidecar
contract (`schema_version == 1`, field order, `audio_sha1`
semantics) that this parser accepts byte-for-byte. Slice 5 requires
only `CacheDb.knnByEmbedding` + `TrackStatus.ready` as its filter.

## 4. Docs to refresh

Run every command before any Dart; save a ≤5-line "API summary"
per library in a scratch file to catch training-data drift.

### `sqflite`

- `resolve-library-id libraryName: "sqflite"`, then `query-docs`
  `topic: "openDatabase transaction batch onConfigure onUpgrade Database execute rawQuery"`.
- **Summary:** `openDatabase(path, version:, onConfigure:, onCreate:,
  onUpgrade:)`; `PRAGMA journal_mode = WAL` goes in `onConfigure`;
  `Batch` for multi-row upserts; no raw handle exposed — extension
  loading uses the companion Dart `sqlite3` FFI on the same file.

### `sqlite3_flutter_libs` + `sqlite3` (Dart)

- `resolve-library-id libraryName: "sqlite3_flutter_libs"` + `query-docs`
  `topic: "bundled sqlite3 open extension loadable Android linux"`.
- `resolve-library-id libraryName: "sqlite3"` + `query-docs`
  `topic: "Database openDynamicLibrary loadExtension allowLoadExtension prepare select"`.
- **Summary:** `sqlite3_flutter_libs` bundles the library so Dart's
  `sqlite3` finds it without system deps. FFI:
  `Database.allowLoadExtension = true` → `db.loadExtension(path)`.
  Some 0.x releases also need `PRAGMA load_extension = 1`; confirm.

### `sqlite-vec` (`vec0`)

- `WebFetch https://github.com/asg017/sqlite-vec` — README,
  extension filename (`vec0.so` / `.dylib`), min SQLite version.
- `WebFetch https://github.com/asg017/sqlite-vec/blob/main/docs/api-reference.md`
  — `CREATE VIRTUAL TABLE … USING vec0(…)`, `vec_distance_l2`,
  `MATCH`/`k=` spelling, `rowid` stability.
- `WebFetch https://github.com/asg017/sqlite-vec/releases` —
  prebuilts for `android-arm64`, `android-x86_64`, `linux-x86_64`;
  record tag + SHA256.
- **Summary:** PK is `track_id INTEGER PRIMARY KEY` (use for all
  joins; `rowid` unstable). kNN: `SELECT track_id, distance FROM
  track_embeddings WHERE embedding MATCH ? AND k = ? ORDER BY
  distance`.

### `json_serializable` + `json_annotation` + `build_runner`

- `resolve-library-id libraryName: "json_serializable"` + `query-docs`
  `topic: "JsonSerializable fromJson toJson explicitToJson fieldRename includeIfNull"`.
- **Summary:** `@JsonSerializable()` on `Sidecar`; codegen via
  `build_runner`; unknown keys ignored by default (matches spec
  rule); `@JsonKey(name: 'audio_sha1')` maps snake→camel.

### `path_provider`

- `resolve-library-id libraryName: "path_provider"` + `query-docs`
  `topic: "getApplicationSupportDirectory getApplicationDocumentsDirectory linux android"`.
- **Summary:** `getApplicationSupportDirectory()` is the stable
  writable root on both Linux (`~/.local/share/...`) and Android
  (app-scoped). `CacheDb` opens `<support>/prism/cache.db`.

### `crypto`

- `resolve-library-id libraryName: "crypto"` + `query-docs`
  `topic: "Digest sha1 convert ChunkedConversionSink"`.
- **Summary:** `sha1.convert(bytes)` one-shot;
  `sha1.startChunkedConversion(sink)` for the tamper sensor
  (§10 risk 4). Canonical equality is `sidecar.audio_sha1 ==
  previous_sidecar.audio_sha1`, never recomputed PCM on phone.

### `watcher` (stretch, feature-flagged)

- `resolve-library-id libraryName: "watcher"` + `query-docs`
  `topic: "DirectoryWatcher events filesystem linux inotify android"`.
- **Summary:** `DirectoryWatcher(path).events` yields
  `WatchEvent(type, path)`. Inotify in Android scoped storage is
  unreliable on older releases — stays behind a flag defaulted off;
  Re-scan is canonical.

## 5. Architecture & data flow

```
 Syncthing folder (source of truth) — filesystem reads only
   ~/Music/Artist/Album/01 - Track.flac
   ~/Music/Artist/Album/01 - Track.sonic.json   ◄ slice 3
                 │
                 ▼
 LibraryScanner (slice 1) ─► SidecarReader (packages/core)
   parse + validate audio_sha1, schema_version, analyzer_models
                 │
                 ▼
 IngestCoordinator
   upsert tracks + track_embeddings(vec0);
   missing audio → missing_audio; stale sidecar → analysis_pending
                 │
                 ▼
 CacheDb (packages/core) = sqflite (writes) + sqlite3 FFI (reads,
                           vec0 kNN hot path) on the same file
      │                    │                     │
      ▼                    ▼                     ▼
 MoodQuery            VibeQuery            knnByEmbedding
 (5 home chips:       (classifier chips    (slice 5 seed →
 Happy Sad Chill      + tempo band)        similar tracks)
 Energetic Focus)           │                     │
      ▼                     ▼                     ▼
 Home mood row    Library → Vibe browse    Radio feed (slice 5)

 PlaybackService reads measured replaygain_*_db from CacheDb by
 path; falls back to tag RG when status != 'ready'.
```

Two SQLite handles on the same file: `sqflite` for async
transactional writes; Dart `sqlite3` FFI for `vec0` load and the
kNN hot path. Single-writer; WAL lets FFI reads stay lock-free.

## 6. File layout (new files only)

```
/packages/core/lib/src/sidecar/sidecar.dart          # Sidecar dataclass (json_serializable)
/packages/core/lib/src/sidecar/sidecar.g.dart        # generated fromJson/toJson
/packages/core/lib/src/sidecar/mood_vector.dart      # MoodVector value type
/packages/core/lib/src/sidecar/sidecar_reader.dart   # read + validate one .sonic.json
/packages/core/lib/src/sidecar/staleness.dart        # StalenessReason enum
/packages/core/lib/src/db/cache_db.dart              # sqflite + sqlite3 FFI pair
/packages/core/lib/src/db/migrations.dart            # Migrations v1 (DDL below)
/packages/core/lib/src/db/vec_loader.dart            # FFI extension loading
/packages/core/lib/src/db/track_status.dart          # TrackStatus enum + mapping
/packages/core/lib/src/db/mood_query.dart            # MoodQuery.run(chip)
/packages/core/lib/src/db/vibe_query.dart            # VibeQuery.run(mood, band)
/packages/core/lib/src/db/knn.dart                   # knnByEmbedding(seed, k)
/packages/core/lib/src/ingest/ingest_coordinator.dart# scan → upsert loop
/packages/core/lib/src/ingest/upsert.dart            # row builder + embedding bytes
/packages/core/test/sidecar_reader_test.dart
/packages/core/test/staleness_test.dart
/packages/core/test/migrations_test.dart
/packages/core/test/mood_query_test.dart
/packages/core/test/vibe_query_test.dart
/apps/mobile/lib/screens/home_screen.dart            # hosts the 5-chip Mood row
/apps/mobile/lib/widgets/mood_chip_row.dart          # fixed 5-chip scroller
/apps/mobile/lib/screens/mood_results_screen.dart    # filtered list + ranked sort
/apps/mobile/lib/screens/vibe_browse_screen.dart     # Library → Vibe
/apps/mobile/lib/widgets/tempo_band_chips.dart       # calm/mid/hot segmented
/apps/mobile/lib/providers/cache_db_providers.dart
/apps/mobile/lib/providers/ingest_providers.dart
/apps/mobile/native/android/vec0/arm64-v8a/vec0.so   # committed prebuilt, SHA256-pinned
/apps/mobile/native/android/vec0/x86_64/vec0.so      # simulator
/apps/mobile/native/linux/x86_64/vec0.so             # desktop
/apps/mobile/native/README.md                        # origin, release tag, checksums
```

Native binaries are small, hash-pinned, and committed — offline-
reproducible builds; same discipline as slice 3's model pins.

## 7. Interfaces & key types

```dart
// sidecar.dart
@JsonSerializable()
class Sidecar {
  final int schemaVersion;            final String analyzer;
  final List<String> analyzerModels;  final String audioSha1;
  final double durationSec;           final int sampleRate;  final int? bitDepth;
  final double bpm, bpmConfidence;    final String key;      final double keyConfidence;
  final double loudnessLufs, replaygainTrackDb, replaygainAlbumDb;
  final double spectralCentroidMean, danceability, voiceInstrumental;
  final MoodVector mood;              final List<GenreTop> genreTop3; // exactly 3
  final String embeddingModel;        final List<double> embedding;   // length 1280
  factory Sidecar.fromJson(Map<String, dynamic> j) => _$SidecarFromJson(j);
  Map<String, dynamic> toJson() => _$SidecarToJson(this);
}

// sidecar_reader.dart
class SidecarReader {
  static const int currentSchemaVersion = 1;
  static const Set<String> compatibleAnalyzerModels = {
    'musicnn-msd-2', 'discogs-effnet-bs64-1',
  };
  Future<SidecarReadResult> read(File file);   // never throws
}
sealed class SidecarReadResult {}
class SidecarReady   extends SidecarReadResult { final Sidecar sidecar; }
class SidecarStale   extends SidecarReadResult { final StalenessReason reason; final String detail; }
class SidecarMissing extends SidecarReadResult {}
enum StalenessReason { schemaMismatch, analyzerMismatch, malformedJson, conflictCopy }

// track_status.dart — persisted as TEXT; all mood/vibe/kNN filter status='ready'
enum TrackStatus { ready, analysisPending, missingAudio }

// cache_db.dart
class CacheDb {
  static Future<CacheDb> open({required String path});
  Future<void> close();
  Database          get sqflite;   // write path
  sqlite3.Database  get ffi;       // read path (vec0)
  MoodQuery get moods;  VibeQuery get vibes;
  Future<List<KnnHit>> knnByEmbedding({required int seedTrackId, int k = 25});
}

// mood_query.dart — locked 5-chip visual order
enum MoodChip { happy, sad, chill, energetic, focus }
class MoodQuery { Future<List<RankedTrack>> run(MoodChip chip, {int limit=200}); }
// Rank = mood_confidence(chip) * log(1 + play_count) * recency_factor
// recency_factor = 0.5 + 0.5 * exp(-days_since_added / 365)
// happy=mood_happy; sad=mood_sad;
// chill=mood_relaxed * (bpm<110 ? 1 : 0.5);
// energetic=max(mood_party, danceability) * (bpm>110 ? 1 : 0.5);
// focus=voice_instrumental * (1-mood_aggressive) * (1-mood_party)

// vibe_query.dart — classifier-native; <90 / 90–120 / >120 bpm
enum VibeMoodChip { happy, sad, aggressive, relaxed, party }
enum TempoBand    { calm, mid, hot }
class VibeQuery {
  Future<List<Track>> run({required VibeMoodChip mood, TempoBand? band, int limit=200});
}
```

### SQL DDL (lifted verbatim from `docs/spec.md`)

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

Slice-4 additions (same v1 migration, different file):

```sql
ALTER TABLE tracks ADD COLUMN status            TEXT NOT NULL DEFAULT 'ready';
ALTER TABLE tracks ADD COLUMN analyzer_models   TEXT;   -- JSON array, resume check
ALTER TABLE tracks ADD COLUMN schema_version    INTEGER;
ALTER TABLE tracks ADD COLUMN play_count        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tracks ADD COLUMN last_played_at    INTEGER;
CREATE INDEX tracks_status       ON tracks(status);
CREATE INDEX tracks_mood_happy   ON tracks(mood_happy);
CREATE INDEX tracks_mood_sad     ON tracks(mood_sad);
CREATE INDEX tracks_mood_relaxed ON tracks(mood_relaxed);
CREATE INDEX tracks_mood_party   ON tracks(mood_party);
CREATE INDEX tracks_bpm          ON tracks(bpm);
```

## 8. Implementation steps

Ordered. Each step names its files and a one-line pass criterion.
Step 3 is standalone and highest-risk — do not skip ahead.

1. **Refresh docs.** Run every command in §4; write ≤5-line API-
   summary notes for extension loading + kNN `MATCH`/`k=`.
   **Pass:** notes exist with concrete spellings.

2. **Ship prebuilt `vec0` binaries.** Commit the refresh-tagged
   release for `android-arm64`, `android-x86_64`, `linux-x86_64`
   under `/apps/mobile/native/`; `native/README.md` records upstream
   tag + per-file SHA256; no auto-download at build. **Pass:**
   `sha256sum` matches pins.

3. **Implement `vec_loader.dart` (highest-risk step).** FFI paths
   diverge per platform:

   ```dart
   // packages/core/lib/src/db/vec_loader.dart (skeleton)
   Future<void> loadVec0Into(sqlite3.Database ffi) async {
     final libPath = await _resolveVec0Path();
     ffi.allowLoadExtension = true;        // required by sqlite3.dart
     try { ffi.loadExtension(libPath); }   // spelling via §4 refresh
     finally { ffi.allowLoadExtension = false; }
   }
   Future<String> _resolveVec0Path() async {
     if (Platform.isAndroid) {
       // Copy from flutter_assets to <support>/native/vec0.so once;
       // ABI via DeviceInfoPlugin.supported64BitAbis (arm64-v8a,
       // x86_64; no armeabi-v7a).
       return _ensureCopied('vec0/${_androidAbi()}/vec0.so');
     }
     if (Platform.isLinux) {
       // Bundle-relative: resolvedExecutable/../lib/vec0.so.
       // Dev override: PRISM_VEC0_PATH env var.
       return _linuxVec0Path();
     }
     throw UnsupportedError('vec0 not prebuilt for ${Platform.operatingSystem}');
   }
   ```

   **Pass:** `migrations_test.dart` opens a fresh DB, calls
   `loadVec0Into`, `ffi.select('SELECT vec_version()')` returns
   non-empty on Linux and Android.

4. **Implement `Migrations` + `CacheDb.open`.** Migrations apply v1
   DDL (spec + slice-4 additions) in a transaction. `CacheDb.open`
   opens the same file twice: `sqflite.openDatabase` with
   `onConfigure` running `loadVec0Into(ffi)` on the paired FFI
   handle *before* schema touches (vec0 must load before `CREATE
   VIRTUAL TABLE`); then `sqlite3.open` for reads. **Pass:** after
   open+apply, `track_embeddings` exists in `sqlite_master`;
   close/reopen idempotent.

5. **Implement `SidecarReader` + staleness evaluator.** `read(file)`:
   `SidecarMissing` on ENOENT; `SidecarStale` when `schemaVersion
   != 1` OR `analyzerModels` disjoint from
   `compatibleAnalyzerModels` OR JSON malformed OR filename matches
   `*.sync-conflict-*.sonic.json`; `SidecarReady` otherwise.
   **Pass:** `sidecar_reader_test.dart` covers each reason;
   `staleness_test.dart` locks the version matrix.

6. **Implement `upsert.dart`.** Builds the `tracks` row and the
   `embedding` bytes (little-endian IEEE-754 float32 `Uint8List`,
   5120 bytes for 1280 dims — vec0's format). Tamper-sensor failure
   (§10 risk 4) upserts `status='analysis_pending'` (tags kept,
   excluded from mood/vibe). **Pass:** fixture upsert yields one
   `tracks` row (`ready`) + one `track_embeddings` row with
   `vec_distance_l2(embedding, embedding) = 0.0`.

7. **Implement `IngestCoordinator`.** Consumes slice 1's
   `Stream<ScanEvent>`: `ScanDiscovered` → read sidecar + upsert +
   store `sidecar_mtime`; `ScanDone` → flip `missing_audio` on rows
   whose `path` didn't appear this scan (single transaction).
   Exposes `Stream<IngestEvent>` (progress + summary). **Pass:**
   5 pairs + 1 orphan audio + 1 orphan sidecar → `5 ready,
   1 analysis_pending, 0 dropped`; orphan sidecar skipped.

8. **Implement `MoodQuery`.** Translate each home-row chip into SQL
   against `tracks`. Ranking in Dart (reusable for `play_count` /
   `last_played_at` later): SQL picks top-1k by relevant mood
   column, Dart applies `confidence * log(1 + play_count) *
   recency_factor`, truncates to `limit`; `status = 'ready'`
   mandatory. **Pass:** seeded 30 rows → each chip's top row has
   the highest relevant confidence.

9. **Implement `VibeQuery`.** SQL on the five classifier-native
   mood cols + optional tempo-band (`< 90`, `BETWEEN 90 AND 120`,
   `> 120`), `status = 'ready'`, `ORDER BY mood_<chip> DESC
   LIMIT ?`. **Pass:** cross-filter `party × hot` → rows all
   satisfy `mood_party > 0.3 AND bpm > 120`.

10. **Implement `knnByEmbedding`.** FFI query (syntax confirmed at
    refresh):
    ```sql
    SELECT te.track_id,
           vec_distance_l2(te.embedding, seed.embedding) AS d
      FROM track_embeddings te,
           (SELECT embedding FROM track_embeddings
             WHERE track_id = ?) seed
     WHERE te.embedding MATCH seed.embedding AND te.k = ?
     ORDER BY d;
    ```
    Joined on `tracks` to drop the seed and non-`ready` rows.
    **Pass:** 30 rows with a near-duplicate of the seed, `k=5` →
    duplicate in position 0, `d < 0.01`.

11. **Wire `PlaybackService` to measured RG.** Optional `CacheDb`
    dep in `packages/playback`; before `setVolume`, prefer cache
    `replaygain_track_db` (or album) over tag RG when row is
    `ready`. **Pass:** tag `-8 dB` + cache `-6 dB` → plays at
    `dbToLinear(-6) ± 1e-3`.

12. **Build Home mood row + results screen.** `HomeScreen` hosts a
    horizontal `MoodChipRow` of the five chips in locked order
    **Happy / Sad / Chill / Energetic / Focus** (large Material 3
    FilterChip pills); tap → `MoodResultsScreen.route(chip)`;
    `ListView` over `moodResultsProvider(chip)`; row tap →
    `QueueService.loadContext`. **Pass:** chips in order; tapping
    Chill opens a §7-sorted list, first row plays.

13. **Build Vibe browse.** Library → new "Vibe" section above
    Albums/Artists/Genres: horizontal `VibeMoodChip` pills above a
    tempo-band segmented control (`calm | mid | hot | off`). List
    live-updates via `vibeResultsProvider((mood, band))`. **Pass:**
    `relaxed + calm` shows only rows with high `mood_relaxed` and
    `bpm < 90`.

14. **Settings: Re-scan + stats.** Append to slice 1's placeholder
    Library section: "Re-scan library" row with progress bar;
    "Cache stats" row with `ready / analysis_pending /
    missing_audio` counts. **Pass:** delete a sidecar + Re-scan →
    `ready` −1, `analysis_pending` +1.

15. **Run §11.** **Pass:** every numbered item green.

## 9. Alternatives considered

**Drift ORM instead of raw `sqflite` + `sqlite3` FFI.** Gives
compile-time-checked queries — removes typo bugs. Rejected: Drift's
runtime wraps SQLite in its own isolate plumbing and adds friction
to loading `vec0`; the `loadExtension`-via-Drift path is
undocumented at our target version, and vec0 is read-heavy / write-
simple so the query builder earns little. Reconsider if Drift
gains first-class extension-loading docs *and* a compile-time
binding for `MATCH`/`k=`.

**Embeddings as a BLOB column on `tracks`, no `vec0` virtual
table.** Simpler: one table, no FFI, no third-party `.so`. Slice 5
kNN becomes "load all BLOBs, L2 in Dart" — ~25 MB RAM and ~5 ms
query at 5k tracks; fine on laptop, tight on a phone hosting
Cactus + Qwen3. Rejected: vec0 is the right tool, hash-pins
cleanly, scales past 50k. Reconsider only if vec0 Android ABI
churn (§10 risk 3) becomes unmanageable.

**A separate SQLite DB per library root.** If Prism ever points at
multiple roots, per-root DBs avoid stale rows when a root unplugs.
Rejected: slice 1's `defaultLibraryRoot()` is single-path, spec
scopes to one folder, multi-DB complicates every later query for a
feature no one has asked for. Reconsider if multi-root becomes
real; migration is mechanical (`root_id` FK).

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|------|-----------|
| 1 | Partial sync: audio present, sidecar absent. | `SidecarMissing` → row kept with tag metadata, `status='analysis_pending'`; excluded from mood/vibe/kNN. Next Syncthing cycle delivers sidecar; re-scan promotes to `ready`. |
| 2 | Partial sync: sidecar present, audio absent. | Orphan sidecar skipped at scan time (no row to attach). If audio later appears without sidecar being re-observed, reconcile leaves it `analysis_pending`. |
| 3 | `vec0` ABI mismatch on Android (wrong ABI copied, NDK drift). | ABI probe reads from runtime, not build config. On `loadExtension` failure, `CacheDb.open` enters degraded mode: embedding queries disabled, mood+vibe still work, Settings warning appears. Hotfix swaps the `.so`. |
| 4 | SHA1 of large FLACs is expensive on phone. | Indexer hashes **decoded PCM**; phone cannot cheaply decode. On-device verification is defense-in-depth: cheap `sha1(first_1MiB + last_1MiB + file_size)` "tamper sensor" flips to `analysis_pending` on change. Authoritative equality is `sidecar.audio_sha1 == previous_sidecar.audio_sha1`. "Phone trusts the indexer." |
| 5 | Syncthing conflict sidecars (`*.sync-conflict-*.sonic.json`). | `SidecarReader` treats any `*.sync-conflict-*` sibling as `StalenessReason.conflictCopy`; never promotes off of it; non-conflict sibling wins. INFO-logged once. |
| 6 | `schema_version` bump forces global re-ingest. | Intended. Every cached row fails staleness and flips to `analysis_pending`; desktop re-analyzes; Syncthing propagates; re-ingest completes. Surfaces as a one-time banner. |
| 7 | `vec0` `rowid` stability across re-ingests. | Virtual table PK is `track_id INTEGER PRIMARY KEY`, 1:1 with `tracks.id`. All joins use `track_id`, never `rowid`. `INSERT OR REPLACE` keyed by `track_id` keeps logical identity stable. Full DB rebuild reassigns `tracks.id` — by design, cache is disposable. |
| 8 | Embedding blob format drift between `vec0` versions. | On-disk layout is versioned inside the virtual table metadata and pinned by shipping a specific `vec0.so`. A SQLite-bundle upgrade that changes format is caught at refresh and forces a migration bump. |
| 9 | "Focus" and "Chill" aren't native classifier outputs. | Derived formulas codified in `MoodQuery` (§7). Locked for slice 4; BPM cutoffs and `voice_instrumental` weight exposed only to tests. Do not rename the chips. |
| 10 | Large library ingest (10k tracks) stalls UI. | `IngestCoordinator.run` executes in `Isolate.run`; `CacheDb` opens a second handle pair inside the isolate on the same file. WAL + single-writer discipline handles contention. Target: 5k → ≤90 s on Pixel 9 Pro Fold. |
| 11 | Filesystem watcher unreliability on Android scoped storage. | `watcher` gated behind feature flag defaulted off. Canonical path is manual Re-scan. If enabled and inotify misses events, correctness is unaffected (next Re-scan reconciles); only latency degrades. |
| 12 | `sqflite` vs `sqlite3` FFI view divergence. | Both handles on same file; writes via `sqflite` transactions, reads via FFI in WAL. `journal_mode = WAL` set in `onConfigure`. Cross-handle visibility tested in `migrations_test.dart`. |

## 11. Verification

Run in order. Items 1–5 restate the slice-4 row of
`docs/spec.md`'s verification table concretely.

1. **Fresh open.** Delete `<support>/prism/cache.db`; launch. DB
   opens, v1 DDL applies, `track_embeddings` exists,
   `vec_version()` non-empty on Linux + Android.
2. **Ingest correctness.** Seed 30 fixture pairs; Re-scan;
   `IngestSummary` = `ready=30, analysis_pending=0, missing_audio=0`.
3. **Mood: Sad.** Tap Sad on Home: top 10 have `mood_sad > 0.4`;
   spot-listening three feels plausibly sad; row tap wires
   through `QueueService.loadContext`.
4. **Home reachable in one tap.** From Tracks, Now Playing, Queue,
   and Library, Home is one tap away; mood row is above the fold
   on Pixel 9 Pro Fold inner display and a Linux 1440p window.
5. **Vibe cross-filter.** Library → Vibe, select `relaxed + calm`:
   every row has `mood_relaxed > 0.3 AND bpm < 90`; deselecting
   the band restores any-bpm rows.
6. **kNN seed.** `CacheDb.knnByEmbedding(seedId, k=10)` → 10 rows;
   ≥6 share genre or artist with the seed. Sets slice-5 bar.
7. **Sidecar deletion → analysis_pending.** Delete one
   `.sonic.json`; Re-scan: row flips to `analysis_pending`,
   disappears from mood/vibe; playback still works via tag RG.
8. **Schema-version bump.** Flip `currentSchemaVersion` to 2 on a
   throwaway branch; Re-scan → every row `analysis_pending`. Flip
   back; Re-scan → every row `ready`. No orphan embeddings
   (`COUNT(*) FROM track_embeddings WHERE track_id NOT IN (SELECT
   id FROM tracks WHERE status='ready')` = 0).
9. **SHA1 tamper detection.** Modify audio bytes (sidecar
   unchanged); Re-scan → `analysis_pending`. Restore → `ready`.
10. **Syncthing conflict sidecar.** Drop
    `01 - Track.sync-conflict-20260401-ABC.sonic.json` beside a
    valid sibling: track stays `ready` off the non-conflict file;
    INFO log records the conflict.
11. **Measured RG preferred.** `tag = -8 dB` + `sidecar = -6 dB`
    plays at `dbToLinear(-6) ± 1e-3`; delete sidecar → falls back
    to `-8 dB`.
12. **vec0 ABI fallback.** Rename Android `vec0.so` to simulate
    load failure: `CacheDb` opens degraded; Settings shows
    "Embeddings disabled"; mood/vibe still work; radio unreachable.
13. **Isolate ingest.** 5k-track re-scan on Pixel 9 Pro Fold: UI
    ≥55 fps during scroll; wall clock ≤90 s.
14. **Idempotent re-scan.** Two back-to-back re-scans with zero
    disk changes yield identical summaries; second ≤25% wall clock
    of the first.

## 12. Definition of done

- [ ] Files in §6 exist; `flutter analyze` clean; no Flutter imports
  leak into `packages/core`.
- [ ] `melos run test` green for `sidecar_reader_test`,
  `staleness_test`, `migrations_test`, `mood_query_test`,
  `vibe_query_test`, and the orphan/deletion integration test.
- [ ] `CacheDb.open` succeeds on Linux + Android; `vec_version()`
  non-empty; `track_embeddings` present post-migration.
- [ ] Prebuilt `vec0.so` committed for `arm64-v8a`,
  `android-x86_64`, `linux-x86_64`; `sha256sum` matches pins.
- [ ] `IngestCoordinator` yields expected `ready / analysis_pending
  / missing_audio` counts on the 30-track fixture (§11 item 2).
- [ ] Home mood row shows exactly 5 chips in locked order **Happy
  / Sad / Chill / Energetic / Focus**; each lands on a non-empty
  §7-sorted list.
- [ ] Library → Vibe shows 5 classifier-native chips + tempo-band
  segmented control; cross-filter narrows (§11 item 5).
- [ ] `PlaybackService` prefers measured RG from `CacheDb` when
  `status='ready'`; falls back to tag RG otherwise.
- [ ] Sidecar-deletion + Re-scan flips row to `analysis_pending`,
  removes it from mood/vibe; playback still works via tag RG.
- [ ] `knnByEmbedding(seedId, k)` returns `k` rows, seed excluded,
  ordered by ascending L2, all `status='ready'`.
- [ ] Syncthing conflict sidecars ignored; canonical sibling wins.
- [ ] Schema-version bump (§11 item 8) flips all rows to
  `analysis_pending` without orphaning embeddings.
- [ ] Measured-vs-tag RG precedence test passes within 1e-3.
- [ ] 5k-track re-scan on Pixel 9 Pro Fold ≤90 s; UI ≥55 fps during
  concurrent scroll.
- [ ] §4 "Docs to refresh" commands were executed and API-summary
  notes written before any Dart file was touched.
- [ ] No deferred-work sentinels — every unfinished item is scoped
  to a later slice and linked here by number.
