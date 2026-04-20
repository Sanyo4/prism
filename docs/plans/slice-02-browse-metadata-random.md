# Slice 2 — Browse views, online metadata backfill, Random tab

## 1. Context

Slice 1 shipped a flat `TracksScreen` and an in-memory track set
exposed by `tracksProvider` in
`apps/mobile/lib/providers/library_providers.dart`. That covers "play
a song", not "browse a library". Slice 2 replaces the flat screen
with a tabbed **Library** surface (Albums / Artists / Playlists /
Songs / Random), adds Album and Artist detail routes, and teaches
the home screen a "Can't decide?" row. Albums, artists, and genres
are pure functions of slice 1's `List<Track>`, so all three browse
views are derived Riverpod providers — no new canonical store on
the Flutter side.

Online metadata fills the gaps in user tags: a rip with no art, a
bootleg with no year, a compilation where the artist says "Various".
A new `packages/metadata` package owns the MusicBrainz + CAA + Last.fm
clients, a global `Pacer` enforcing MusicBrainz's 1 req/sec budget,
and a SQLite `metadata_cache` plus path-keyed `track_meta` so rescans
reuse work. A backfill queue runs after `ScanDone`, one track at a
time, writing results to the cache and nudging the in-memory `Track`
via a patch stream. Last.fm is lazier — artist bios and tags only
when the user opens an artist-detail page.

Random tab makes a full library feel like a radio: a seeded `Random`
held in view state, per-section refresh re-seeds. Home gets a 3-album
"Can't decide?" row below a mood-chips placeholder (chips ship in
slice 4). All shuffling is client-side — no `ORDER BY RANDOM()` —
so behavior is identical before and after slice 4's SQLite cache.

## 2. Goals / Non-goals

**Goals**

- `packages/metadata` (pure Dart; deps: `dio`, `sqflite`, `core`)
  exposing `MetadataRepository`, `Pacer`, and the `Mb*` / `Caa*` /
  `LastfmArtistInfo` / `TrackMetadataPatch` models.
- `MetadataRepository.backfill(Track)` fills missing `artist` /
  `album` / `year` + a CAA `coverUrl` where a release MBID resolves.
  `.artistInfo(mbid)` lazily fetches a Last.fm bio + top-5 tags,
  cached 30 days.
- SQLite `metadata_cache` (JSON-per-MBID) and `track_meta` (resolved
  MBIDs per audio path) at schema version 1. Slice 4 bumps version.
- Single global `Pacer` (1 req/sec to MusicBrainz only, expo-backoff
  on 503). CAA and Last.fm keep separate informal budgets.
- Backfill queue runs after `ScanDone(cancelled: false)`; patches
  flow through `trackPatchProvider` so browse rows update in place.
- `albumsProvider`, `artistsProvider`, `genresProvider` — pure
  derivations of `tracksProvider` + the merged patch map.
- `LibraryScreen` with 5 tabs. Playlists shows a "Coming in slice 6"
  empty state; Songs reuses slice 1's list body.
- `AlbumDetailScreen` (hero + tracklist) and `ArtistDetailScreen`
  (avatar, lazy Last.fm blurb, album grid, top tracks).
- `RandomTab`: *Pick an Album* 2×3 grid of 6, *Pick an Artist*
  horizontal × 6, one refresh button per section.
- Home "Can't decide?" row: 3 albums + refresh, under the chips
  placeholder.
- Art via `cached_network_image`, cache key = release MBID, 512 MB
  LRU, 60-day TTL.
- Settings → Online Metadata section: enable toggle, contact email
  (required), Clear Cache.

**Non-goals**

- No global "disable network" switch beyond the metadata toggle
  (slice 7 polish). No lyric fetching (Last.fm endpoint is dead).
- No manual cover-art override; slice 4 honors `.cover.jpg` sidecars.
- No mood chips (slice 4), playlist CRUD (slice 6), drag reorder on
  tracklists (slice 7).
- No MusicBrainz write-back, acoustid fingerprinting, or local
  mirror. Read-only HTTP only.

## 3. Dependencies

Depends on: 1
Unblocks: 7

Slice 7's adaptive palette reads the on-disk CAA cache slice 2 writes.
Slice 4 layers sidecar ingest over the same `metadata_cache`; it
reads rows slice 2 writes but does not change the DDL.

## 4. Docs to refresh

Run before writing Dart. Keep a ≤5-line API summary per library.

### MusicBrainz API (rate limits + user-agent policy)

- `WebFetch https://musicbrainz.org/doc/MusicBrainz_API`
- `WebFetch https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting`
- `WebFetch https://wiki.musicbrainz.org/Development/JSON_Web_Service`

**API summary reminder:** Base `https://musicbrainz.org/ws/2/`, JSON
via `fmt=json`. 1 req/sec per IP for anonymous; silent bans possible.
`User-Agent` must identify app + contact
(`"Prism/0.2.0 ( sanays.mail@gmail.com )"`). Endpoints:
`/recording?query=...`, `/release?query=...`,
`/artist/{mbid}?inc=url-rels+tags`. 503 = slow down; never retry
immediately.

### Cover Art Archive

- `WebFetch https://musicbrainz.org/doc/Cover_Art_Archive/API`
- `WebFetch https://coverartarchive.org/`

**API summary reminder:** No auth. `/release/{mbid}/front-500`
redirects to a 500 px image on Internet Archive; 404 = no art known
(cache the miss). `cached_network_image` follows the redirect.

### Last.fm API (getInfo for artists)

- `WebFetch https://www.last.fm/api/show/artist.getInfo`
- `WebFetch https://www.last.fm/api/intro`

**API summary reminder:** Base
`https://ws.audioscrobbler.com/2.0/`; `method=artist.getInfo&mbid=<>
&api_key=<>&format=json`. Bio at `artist.bio.content`, tags at
`artist.tags.tag[].name`. 5 req/sec informal. Missing key → silent
skip, no error dialog.

### `dio`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "dio"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "BaseOptions interceptors retry timeout user-agent"`.

**API summary reminder:** `Dio(BaseOptions(...))` centralizes base
URL, timeouts, headers. `interceptors.add(InterceptorsWrapper(...))`
for logging + retry. `DioException.type` drives retry logic. Per-
instance headers — never pass per-call.

### `cached_network_image`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "cached_network_image"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "CachedNetworkImage cacheManager diskCacheKey placeholder errorWidget"`.

**API summary reminder:** `CachedNetworkImage(imageUrl:, cacheKey:
mbid, placeholder:, errorWidget:)`. Custom `PrismArtCacheManager`
pins to release MBID so URL variants do not re-download. TTL 60 d,
LRU 512 MB. Android + Linux supported.

### `sqflite`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "sqflite"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "openDatabase onCreate onUpgrade transaction batch"`.

**API summary reminder:** `openDatabase(path, version, onCreate,
onUpgrade)`. Slice 2 opens v1 with `metadata_cache` + `track_meta`.
Slice 4 bumps to v2 and adds `tracks` + `track_embeddings`. DB path:
`getApplicationSupportDirectory()/prism.db`.

## 5. Architecture & data flow

```
  apps/mobile (Riverpod ProviderScope)
  ┌──────────────────────────────────────────────────────────┐
  │ AppShell                                                 │
  │   ├─ HomeScreen         ← "Can't decide?" row of 3       │
  │   ├─ LibraryScreen      ← 5 tabs incl. Random            │
  │   ├─ AlbumDetailScreen     ArtistDetailScreen            │
  │   └─ SettingsScreen     ← Online Metadata section (new)  │
  └──────────┬───────────────────────────────────────────────┘
             │ derived providers
             ▼
  ┌──────────────────────────────────────────────────────┐
  │ albumsProvider | artistsProvider | genresProvider    │
  │ randomAlbumsProvider | randomArtistsProvider         │
  │ trackPatchProvider | artistInfoProvider(mbid)        │
  └──────────┬───────────────────────────────────────────┘
             │ reads
             ▼
  ┌──────────────────┐       ┌──────────────────────────┐
  │ tracksProvider   │ ◄────►│ merged Map<path, Track>  │
  │ (slice 1)        │ patch │ (rebuilt per patch)      │
  └────────┬─────────┘       └────────────┬─────────────┘
           │ ScanDone(cancelled:false)    ▲  TrackPatch
           ▼                              │
  ┌─────────────────────────────────────────────────────┐
  │ BackfillQueue (apps/mobile, headless)               │
  │   for each Track missing artist/album/year:         │
  │     patch = await repo.backfill(track)              │
  │     emit TrackPatch(path, patch) if non-empty       │
  └─────────┬───────────────────────────────────────────┘
            ▼
  ┌───────────────────────────────────────────────────────┐
  │ packages/metadata — MetadataRepository                │
  │   MbClient (Pacer) | CaaClient | LastfmClient         │
  │   ↓ 1 rps                                             │
  │   Pacer (single-slot, expo-backoff on 503)            │
  └──────────────────────┬────────────────────────────────┘
                         ▼
              metadata_cache + track_meta
              (sqflite, prism.db)
```

| Box | Package |
|---|---|
| `MetadataRepository`, `MbClient`, `CaaClient`, `LastfmClient`, `Pacer`, `TrackMetadataPatch`, `MbRecording`, `MbRelease`, `MbArtist`, `CaaArt`, `LastfmArtistInfo` | `packages/metadata` |
| `AlbumView`, `ArtistView`, `GenreView`, `TrackPatch`, browse + random providers | `apps/mobile` |
| `BackfillQueue`, `RandomTab`, `HomeRandomRow`, detail screens, settings section | `apps/mobile` |

`packages/metadata` has zero Flutter imports — testable without a
Flutter engine. Backfill lives in the app (binds Riverpod); the
repository is a plain library.

## 6. File layout (new files only)

```
/packages/metadata/pubspec.yaml
/packages/metadata/lib/metadata.dart                    # barrel
/packages/metadata/lib/src/metadata_repository.dart
/packages/metadata/lib/src/pacer.dart
/packages/metadata/lib/src/clients/mb_client.dart
/packages/metadata/lib/src/clients/caa_client.dart
/packages/metadata/lib/src/clients/lastfm_client.dart
/packages/metadata/lib/src/models/mb_recording.dart
/packages/metadata/lib/src/models/mb_release.dart
/packages/metadata/lib/src/models/mb_artist.dart
/packages/metadata/lib/src/models/caa_art.dart
/packages/metadata/lib/src/models/lastfm_artist_info.dart
/packages/metadata/lib/src/models/track_metadata_patch.dart
/packages/metadata/lib/src/cache/metadata_db.dart
/packages/metadata/lib/src/cache/metadata_dao.dart
/packages/metadata/test/pacer_test.dart
/packages/metadata/test/mb_client_fake_test.dart
/packages/metadata/test/metadata_repository_test.dart
/apps/mobile/lib/browse/album_view.dart
/apps/mobile/lib/browse/artist_view.dart
/apps/mobile/lib/browse/genre_view.dart
/apps/mobile/lib/browse/browse_providers.dart
/apps/mobile/lib/screens/home_screen.dart
/apps/mobile/lib/screens/library_screen.dart
/apps/mobile/lib/screens/album_detail_screen.dart
/apps/mobile/lib/screens/artist_detail_screen.dart
/apps/mobile/lib/screens/random_tab.dart
/apps/mobile/lib/widgets/home_random_row.dart
/apps/mobile/lib/widgets/album_tile.dart
/apps/mobile/lib/widgets/artist_tile.dart
/apps/mobile/lib/widgets/refresh_icon_button.dart
/apps/mobile/lib/backfill/backfill_queue.dart
/apps/mobile/lib/backfill/track_patch.dart
/apps/mobile/lib/providers/metadata_providers.dart
/apps/mobile/lib/shell/settings_online_metadata.dart
/apps/mobile/test/browse_providers_test.dart
/apps/mobile/test/random_tab_test.dart
/apps/mobile/test/backfill_queue_test.dart
```

Two additive touches to slice 1 files (§8): `app.dart` gains routes
for Library + Album + Artist detail; `settings_screen.dart` composes
`SettingsOnlineMetadataSection`.

## 7. Interfaces & key types

```dart
// packages/metadata/lib/src/metadata_repository.dart
abstract class MetadataRepository {
  Future<TrackMetadataPatch> backfill(Track track);
  Future<LastfmArtistInfo?> artistInfo(String mbid);
  Future<String?> coverArtUrl(String releaseMbid);
  Future<void> clearCache();
  bool get configured;   // false when contact email empty
}
```

```dart
// packages/metadata/lib/src/pacer.dart
class Pacer {
  Pacer({required Duration interval,
         Duration maxBackoff = const Duration(seconds: 64)});
  /// Awaits next slot, runs [fn]. On Pacer503Exception, doubles the
  /// delay up to [maxBackoff] and retries once; second 503 bubbles.
  Future<T> run<T>(Future<T> Function() fn);
}
class Pacer503Exception implements Exception { final Duration retryAfter; }
```

```dart
// packages/metadata/lib/src/models/track_metadata_patch.dart
class TrackMetadataPatch {
  final String? artist, albumArtist, album, genre;
  final int? year, trackNo, discNo;
  final String? recordingMbid, releaseMbid, artistMbid, coverUrl;
  const TrackMetadataPatch({...});
  bool get isEmpty; bool get isNotEmpty;
  static const empty = TrackMetadataPatch();
}
```

```dart
// apps/mobile/lib/browse/album_view.dart
class AlbumView {
  final String id;                // '${albumArtist ?? artist}∷${album}'
  final String title;
  final String artist;
  final int? year;
  final String? coverUrl;         // null → gradient fallback tile
  final List<Track> tracks;
  int get trackCount;
  Duration get totalDuration;
}
List<AlbumView> indexAlbums(
    List<Track> tracks, Map<String, String?> coverByReleaseMbid);
```

```dart
// apps/mobile/lib/browse/artist_view.dart
class ArtistView {
  final String id;                // albumArtist || artist, lower-trim
  final String name;
  final int albumCount;
  final int trackCount;
  final String? mbid;
  final List<AlbumView> albums;   // sort: year desc, title asc
  final List<Track> topTracks;    // longest 5 until slice 4 has plays
}
List<ArtistView> indexArtists(List<Track> tracks, List<AlbumView> albums);
```

```dart
// apps/mobile/lib/browse/genre_view.dart
class GenreView {
  final String id;                // lower-cased label
  final String label;             // prettified
  final int trackCount;
  final int artistCount;
  final Color accent;             // deterministic hash → pastel
}
List<GenreView> indexGenres(List<Track> tracks);
```

```dart
// apps/mobile/lib/screens/random_tab.dart
class RandomTab extends ConsumerStatefulWidget { const RandomTab({super.key}); }
class _RandomTabState extends ConsumerState<RandomTab> {
  int _albumSeed  = DateTime.now().microsecondsSinceEpoch;
  int _artistSeed = DateTime.now().microsecondsSinceEpoch ^ 0x9E3779B1;
  List<AlbumView>  _pickAlbums(List<AlbumView>  all) =>
      (List.of(all)..shuffle(Random(_albumSeed))).take(6).toList();
  List<ArtistView> _pickArtists(List<ArtistView> all) =>
      (List.of(all)..shuffle(Random(_artistSeed))).take(6).toList();
}
```

Seed is view-state, not persisted — navigating away and back
re-shuffles by design. `HomeRandomRow` holds its own seed.

### `metadata_cache` SQL DDL (schema version 1)

Slice 4 bumps version and adds `tracks` + `track_embeddings`.
Slice 2 creates:

```sql
CREATE TABLE metadata_cache (
  kind       TEXT NOT NULL,     -- 'recording' | 'release' | 'artist' | 'caa' | 'lastfm_artist'
  mbid       TEXT NOT NULL,
  payload    TEXT NOT NULL,     -- raw upstream JSON
  fetched_at INTEGER NOT NULL,  -- unix ms
  expires_at INTEGER NOT NULL,  -- unix ms; 30 d lastfm+artist, 365 d else
  PRIMARY KEY (kind, mbid)
);
CREATE INDEX metadata_cache_expires ON metadata_cache(expires_at);

CREATE TABLE track_meta (
  path            TEXT PRIMARY KEY,  -- absolute filesystem path
  recording_mbid  TEXT,
  release_mbid    TEXT,
  artist_mbid     TEXT,
  patched_at      INTEGER NOT NULL,  -- 0 = tried, got nothing
  attempt_count   INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT
);
CREATE INDEX track_meta_release ON track_meta(release_mbid);
CREATE INDEX track_meta_artist  ON track_meta(artist_mbid);
```

`kind`+`mbid` is the composite PK; `payload` carries raw JSON so
later slices extract fields without re-fetching. `track_meta`
lets the backfill queue cheaply skip "already tried" tracks and
lets Settings wipe both tables in one transaction.

## 8. Implementation steps

Each step: ~20–80 LOC, names files, one-line pass criterion.

1. **Add `packages/metadata` to Melos.** Pubspec (Dart SDK, `dio`,
   `sqflite`, `sqflite_common_ffi`, path dep on `core`), bootstrap.
   **Pass:** `melos list` prints four packages; `dart pub get` in
   the new package succeeds.

2. **Write `Pacer`.** FIFO single-slot mutex, one token per
   `interval`. `Pacer503Exception` doubles the interval, retries
   once, then bubbles.
   **Pass:** `pacer_test.dart` — 5 calls take ≥ 4 × interval − 20 ms;
   simulated 503 backs off correctly.

3. **`MbClient`.** `Dio` with base `ws/2/`, `User-Agent` from ctor.
   `searchRecording(title, artist)` + `searchRelease(album, artist)`,
   both Pacer-gated; parse into `MbRecording` / `MbRelease`.
   **Pass:** `mb_client_fake_test.dart` parses canned response.

4. **`CaaClient`.** One method `frontUrl(releaseMbid)` returning
   `https://coverartarchive.org/release/$mbid/front-500`. HEAD
   verifies, 404 → null. No Pacer.
   **Pass:** unit test proves URL shape + null-on-404.

5. **`LastfmClient`.** GET `/2.0/?method=artist.getInfo&mbid=...
   &api_key=...&format=json`. Parse `artist.bio.content` and top-5
   `artist.tags.tag[].name`. Missing API key → `null`, not throw.
   **Pass:** fixture parses 5 tags + non-empty bio.

6. **Open `prism.db` v1.** `metadata_db.dart` at
   `getApplicationSupportDirectory()/prism.db`, `onCreate` runs §7
   DDL. `metadata_dao.dart` exposes `upsertCache`, `readCache`,
   `upsertTrackMeta`, `readTrackMeta`, `clearAll`. Expired rows
   (`expires_at < now`) treated as absent.
   **Pass:** DAO round-trip + expiry short-circuit under
   `sqflite_common_ffi`.

7. **Compose `MetadataRepository`.** Ctor takes clients, DAO, and
   a `SettingsSnapshot` (email + lastfm key). `backfill()`:
   unconfigured → `empty`; `track_meta` hit → stored patch; else
   MB recording search (conf ≥ 80) → top release → CAA → assemble
   patch filling only tag-missing fields → upsert both tables.
   **Pass:** `metadata_repository_test.dart` covers unconfigured
   no-op, cache-hit no-network, and successful fill with cover.

8. **Derive `AlbumView` / `ArtistView` / `GenreView`.** Pure fns
   over `List<Track>`. Album id: `albumArtist ?? artist` + `∷` +
   `album`; missing title → `"Unknown Album"`. Artists sort by
   name; albums by year desc then title. Genres drop empty + literal
   `"Unknown"`.
   **Pass:** `browse_providers_test.dart` asserts stable ids and
   groupings on a 50-track fixture.

9. **Riverpod browse providers.** `albumsProvider`,
   `artistsProvider`, `genresProvider` watch `tracksProvider` plus
   the merged patch map.
   **Pass:** provider test — 3 patches applied → 3 albums.

10. **Backfill queue.** Listens `libraryScanProvider` for
    `ScanDone(cancelled: false)`; filters tracks missing
    artist/album/year with no `track_meta` row; awaits
    `repo.backfill(track)` and emits `TrackPatch`; checks Settings
    between requests; persists attempt state.
    **Pass:** `backfill_queue_test.dart` — 100 tracks, 40 missing,
    40 patches emitted; mid-run pause observed.

11. **Merge patches.** `trackWithPatchProvider` joins
    `tracksProvider` with `trackPatchProvider.stream` into
    `Map<String, Track>`. Browse providers read from this map.
    **Pass:** widget test — injected patch → album list rebuilds
    with new cover.

12. **`HomeRandomRow`.** Stateful, seed int. Three 96×96
    `CachedNetworkImage` tiles inside `Glass`, labels beneath,
    trailing `RefreshIconButton` bumps seed. Rendered under a
    `SizedBox(height: 44)` mood-chips placeholder.
    **Pass:** widget test — 3 tiles, refresh → different ordering.

13. **`RandomTab`.** *Pick an Album* 2×3 grid of `AlbumTile`;
    *Pick an Artist* horizontal `ListView` of 6 `ArtistTile`s. Two
    section headers, two refresh buttons, independent seeds.
    **Pass:** `random_tab_test.dart` — 6 + 6 ids, per-section
    refresh changes only that section.

14. **Library screen tabs.** Replace slice 1's `TracksScreen` route
    with `LibraryScreen` holding a `DefaultTabController` of 5
    tabs. Albums grid = `AlbumTile`s; Artists grid = `ArtistTile`s;
    Playlists = empty-state card ("Coming in slice 6"); Songs =
    slice 1's list extracted into `SongsTab`; Random = `RandomTab`.
    **Pass:** manual — each tab renders, tab switch is immediate.

15. **Detail screens.** `AlbumDetailScreen(id)` resolves the
    `AlbumView`, renders hero art + tracklist, tap routes through
    `QueueService.loadContext`. `ArtistDetailScreen(id)` draws
    avatar, `artistInfoProvider(mbid)` blurb when present, tags +
    albums + top tracks. No blurb when mbid null or Last.fm key
    absent.
    **Pass:** manual — tile tap → detail; track tap → playback.

16. **Settings: Online Metadata.** Appended to `SettingsScreen`:
    `SwitchListTile` toggle, email `TextField`, destructive
    "Clear metadata cache" button with confirm dialog.
    `SharedPreferences` persistence. Empty email + toggle on →
    yellow `Banner`: "Enter a contact email — MusicBrainz refuses
    anonymous traffic."
    **Pass:** restart preserves settings; toggle off → next scan
    runs no MB requests.

17. **Run §11 verification.** **Pass:** every numbered item green.

## 9. Alternatives considered

**(a) Ship without online metadata.** Cheapest: skip the network
layer, render browse views from tags alone. Cost: tagless CD rips
look ugly, compilation releases fragment the artist list, missing
years break chronological sort. Chose against because Apple
Music-style browse is only as good as its art and grouping, and MB
fills the 10 % of the library tags miss for free.
**Reconsider if:** users get rate-limit bans in the wild or CAA hit
rate drops below 50 %.

**(b) Discogs instead of MusicBrainz.** Richer label data, 60 req/min
published limit. Cost: OAuth required past the 25 req/min anonymous
cap, licensed cover art with attribution burden, weaker artist
relationships. Chose MB because CAA art is one redirect from a
release MBID, no auth to start, and `docs/spec.md` § Stack locked it
in. **Reconsider if:** MB bans traffic we do not understand or a
pressing-info feature appears in slice 7.

**(c) Server-side shuffle via `ORDER BY RANDOM()` vs client-side.**
`RANDOM()` is O(n log n) without a covering index and does not let
the UI pin a seed for "scroll, refresh, same order until I tap
Refresh." `List.shuffle(Random(seed))` is O(n), seedable, and works
identically before + after slice 4's cache. Slice 2 also does not
own a query-ready `tracks` table — that is slice 4.
**Reconsider if:** libraries exceed 100 k tracks and shuffle shows
up in frame traces.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | MusicBrainz rate-limit ban from a bug loop. | `Pacer` is the only entry to `MbClient`; integration test asserts ≥ 1000 ms between consecutive calls. |
| 2 | Contact email missing — MB refuses anonymous. | Fail-closed: `configured == false`, `backfill()` returns `empty`, Settings shows a yellow banner. Zero traffic until the user fills it in. |
| 3 | CAA 404 for a known release MBID. | Cache the miss (`payload='{}'`, 365 d). UI falls back to the gradient tile. |
| 4 | Last.fm API key absent. | `artistInfo()` short-circuits to null. Artist detail hides the blurb with one muted nudge line. No modal, no nag. |
| 5 | Offline at scan time. | `backfill()` catches connection errors → stores `track_meta(last_error='offline', patched_at=0)`; next online scan retries once per track. |
| 6 | Shuffled-seed scroll-off (art lazy loads, tiles pop in). | Seed stable until refresh; layout driven off shuffled list, not load order. Unloaded art shows gradient + title overlay. |
| 7 | Backfill queue never terminates on a 50 k library. | `attempt_count` capped at 3 lifetime; above that, track considered "tagless as shipped" and skipped. |
| 8 | Fold rotation mid-backfill doubles the queue. | `BackfillQueue` lives in a singleton `Provider` (not autoDispose), keyed by container not widget; rotation does not restart it. |
| 9 | Patch stream arrives after widget dispose. | `trackPatchProvider` is a `StreamProvider`; Riverpod gates rebuild behind `ref.mounted`. |
| 10 | Embedded art vs CAA disagree. | UI composes `embeddedArt ?? cachedCaa ?? gradientFallback`; slice 1's `audiotags` pictures win. |
| 11 | User flips toggle mid-run. | Queue checks `configured` between requests; in-flight completes, loop exits, position persisted. |
| 12 | Corrupt SQLite (fs truncation). | `openDatabase` in try/catch; on failure delete file + reopen fresh. Loses cache, no user data. |

## 11. Verification

1. `melos bootstrap` → `melos run test` green across all four
   packages (slice 1 + `pacer_test`, `mb_client_fake_test`,
   `metadata_repository_test`, `browse_providers_test`,
   `random_tab_test`, `backfill_queue_test`).
2. Online Metadata disabled, tags intact: open Library → Albums
   grid shows one tile per `album_artist∷album`; Artists shows one
   per artist; Genres shows one per non-empty genre.
3. Delete `title`/`artist`/`album`/`year`/`genre` on one FLAC. Enter
   contact email, enable toggle, re-scan. Within 5 s of `ScanDone`
   the row refreshes with MB-sourced fields + CAA cover;
   `track_meta` row has non-null `recording_mbid` + `release_mbid`.
4. Toggle off. Delete tags on a second track and re-scan. No
   traffic (airplane mode + `adb logcat | grep Dio`), no
   `track_meta` row; row renders "Unknown Artist — Unknown Album".
5. Clear contact email. Yellow banner appears in the section.
   Toggle on with empty email: zero traffic; banner remains.
6. Random tab → *Pick an Album* renders 6 tiles in 2×3. *Pick an
   Artist* renders 6 horizontally. Per-section refresh yields a
   different selection; navigating away + back re-shuffles.
7. Home "Can't decide?" row shows 3 albums below the chips
   placeholder. Refresh → different 3. Tap a tile → album detail.
8. Artist with a known MBID: detail shows Last.fm bio + 5 tags
   within ≤ 2 s. Rebuild without a key → no blurb, muted nudge.
9. Cold DB: scan a 200-track library, 40 missing `album`. After
   `ScanDone`, 40 patches emit over ≥ 40 s (Pacer). Second launch:
   zero new MB requests, 40 `track_meta` rows.
10. Airplane mode after step 9: browse + art render from cache.
11. Settings → "Clear metadata cache" → both tables empty; next
    scan re-runs backfill from scratch.

## 12. Definition of done

- [ ] `packages/metadata` exists with path deps from `apps/mobile`;
  `melos bootstrap` idempotent; zero Flutter imports leak in.
- [ ] `MetadataRepository`, `Pacer`, `MbClient`, `CaaClient`,
  `LastfmClient` implemented.
- [ ] `metadata_cache` + `track_meta` at schema v1; DDL matches §7.
- [ ] `Pacer` test proves ≥ 1 s spacing + one 503 back-off.
- [ ] Browse providers derive deterministically from
  `tracksProvider` + the merged patch map.
- [ ] `BackfillQueue` persists attempt state; restart does not
  re-query completed or exhausted tracks.
- [ ] `trackPatchProvider` streams patches; browse rows update
  without a full reload.
- [ ] `LibraryScreen` has 5 tabs; Playlists is the empty-state
  card; Songs matches slice 1 byte-for-byte.
- [ ] `RandomTab` renders 6 + 6; per-section refresh isolates.
- [ ] `HomeScreen` shows "Can't decide?" row of 3 below chips.
- [ ] `cached_network_image` keyed by release MBID; 512 MB LRU;
  survives cold start.
- [ ] Settings → Online Metadata: toggle + email + Clear Cache;
  empty-email banner whenever toggle on + email blank; traffic
  ceases when toggle off.
- [ ] `flutter analyze` clean; `melos run test` green.
- [ ] §11 verification run end-to-end on Linux + Pixel 9 Pro Fold.
- [ ] §4 "Docs to refresh" executed; API-summary scratch informed
  ≥ 1 decision in this plan.
- [ ] No deferred-work sentinels; every unfinished item is scoped
  to a later slice and linked here by number.
