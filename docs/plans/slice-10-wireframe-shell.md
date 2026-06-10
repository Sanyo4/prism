# Slice 10 — Wireframe-Aligned Shell (Discover Home, Vibe-Steered Songs, Radio-Aware NowPlaying, Library Polish)

## 1. Context

The mobile shell that landed across slices 1–9 was an MVP layout —
Tracks / Now Playing / Queue / AI bottom nav, Library with six
sub-tabs (Albums / Artists / Playlists / Songs / Random / Vibe).
A subsequent restructure aligned the shell with the design source
in `wireframe/music/` (see `screens/mobile-browse.jsx`,
`mobile-detail.jsx`, `mobile-shell.jsx`): four-tab bottom nav
(Home / Search / Library / Create), MiniPlayer pill, NowPlaying as
a full-screen overlay, custom typographic headers in place of the
Material AppBar.

That restructure was deliberately conservative — five follow-ups
were left for this slice:

1. **Vibe + Random retired** as Library sub-tabs but never resurfaced.
   Their useful behaviour (slice-2 random reseeds, slice-4 vibe
   browsing) currently has no entry point in the wireframe shell.
2. **`apps/mobile/test/widget_test.dart`** still asserts the old
   Material AppBar title ("Library") on the gear-icon route walk;
   `settings_library` may also touch retired routes.
3. **`RadioBadge` + `SteerChipBar`** still render unconditionally
   inside `NowPlayingScreen._PlayerView`. The wireframe doesn't
   show them, but slice-5 radio is real functionality and the
   widgets earn their place when a session is active.
4. **Album-splitting bug**: tracks tagged `"Artist X feat. Y"`
   without an `ALBUMARTIST` tag get grouped into a separate "album"
   from the rest of the release, fragmenting Library → Albums.
5. **Library has no sort or filter affordances**. The wireframe's
   Library header (`mobile-browse.jsx` lines 114-131) shows BOTH
   a grid/list toggle AND a filter button next to the "Library"
   title — neither is wired up today.

This slice closes those five loops. The non-goal is any change to
slice-5's `RadioSession` state machine or slice-4's classifier SQL
— both stay byte-identical; only entry points and renderers move.

## 2. The changes, locked

The five follow-ups from §1 expand into six sub-sections below:
the "Vibe + Random retired" follow-up splits into separate
Random (§2.1) and Vibe (§2.2) treatments because they fold into
different surfaces.

### 2.1 Discover-grid Home (Random retired)

The `RandomTab` route is retired. Its two sections — random albums
and random artists — move into the existing `HomeScreen` as
**discover grids**, slotted between the Featured strip and the
Recently-played grid. Each grid is 2×3, each has its own refresh
button and its own seed (slice-2 invariant: refreshing one section
does not reseed the other). The lift is mechanical — the existing
`RandomTab._AlbumsSection` and `_ArtistsSection` widgets become
private `_DiscoverAlbumsGrid` / `_DiscoverArtistsGrid` under
`apps/mobile/lib/widgets/`, the seed-state notifier comes with them.

Layout under HomeScreen's `ListView`, top → bottom:

```
Greeting block
AI compose card
Mood section (header + chips)
Featured row                              (existing, 1 row, horizontal scroll)
Discover albums       2×3 grid + refresh  ← lifted from RandomTab
Discover artists      2×3 grid + refresh  ← lifted from RandomTab
Artists you love row                      (existing, 1 row, horizontal scroll)
Recently played       2×3 grid            (existing)
```

`RadioHomeCard` (slice-5 LRU of 3 most-recent radio seeds) is
**dropped from Home**. Re-entry into past radio sessions happens
through the new entry points in §2.3 instead.

### 2.2 Vibe-steered Songs tab (Vibe retired)

`VibeBrowseScreen` and its route are retired. Its purpose —
"explore the library by classifier output" — folds into the
`Library → Songs` tab, which becomes the **iPod-shuffle surface**.

The Songs tab body, top → bottom:

```
┌─────────────────────────────────────────────┐
│ Big "Shuffle play" CTA   [○ True Shuffle]   │
│ Steer by vibe                                │
│ [ Happy ][ Sad ][ Chill ][ Energetic ][ Focus ]
│ [ Tempo ▾ ]                                  │
│  ─────────────────────────────────           │
│ Showing N tracks                             │
│ ▸ Track row                                  │
│ ▸ Track row                                  │
│  …                                           │
└─────────────────────────────────────────────┘
```

**Steering rules** — pick one based on chip count. All three
modes cap the deck at `LIMIT 1000` so the visible list and the
shuffle pool stay bounded on libraries with tens of thousands
of tracks; the cap matches slice-4's `MoodQuery` precedent:

| Chip count                        | Mode          | SQL strategy                                                                 |
|-----------------------------------|---------------|------------------------------------------------------------------------------|
| 0 chips, OR True Shuffle ON       | True Shuffle  | `WHERE status='ready' ORDER BY RANDOM() LIMIT 1000`                          |
| 1 chip                            | Filter        | `WHERE <chip.expr> > 0.5 ORDER BY <chip.expr> × recency DESC LIMIT 1000`     |
| 2+ chips                          | Bias / blend  | `WHERE Σ <chip.expr> > 0 ORDER BY (Σ <chip.expr>) × recency DESC LIMIT 1000` |

`<chip.expr>` reuses slice-4's existing composite expressions from
`packages/core/lib/src/db/mood_query.dart` — the chip→column mapping
stays the source of truth so Essentia's classifier output stays the
backing data without re-deriving any thresholds:

| Chip       | SQL fragment                                                           |
|------------|------------------------------------------------------------------------|
| Happy      | `mood_happy`                                                           |
| Sad        | `mood_sad`                                                             |
| Chill      | `mood_relaxed * CASE WHEN bpm < 110 THEN 1.0 ELSE 0.5 END`             |
| Energetic  | `MAX(mood_party, danceability) * CASE WHEN bpm > 110 THEN 1.0 ELSE 0.5 END` |
| Focus      | `voice_instrumental * (1 - mood_aggressive) * (1 - mood_party)`        |

`recency = 1.0 + log(1 + days_since(added_at) ÷ 30)⁻¹` — same
recency factor slice-4 uses, lifted into a shared helper.

**Tempo dropdown** — independent from the chip row; clamps `bpm`
to one of slice-4's existing `TempoBand` values (`calm` <90,
`mid` 90–120, `hot` >120) plus `null` = "Any tempo" (default).
When non-null, ANDs into the `WHERE` clause regardless of which
chip mode is active. The enum + predicate live in
`packages/core/lib/src/db/vibe_query.dart` today and are reused
verbatim — no new band definitions.

**True Shuffle toggle** — when ON, the chip selections dim (still
visible, but greyed). The toggle is a hard override that ignores
chips even when picked — useful for "I selected Chill but actually
just want everything for a minute".

**The list below** is the *deck* — what'll play if you hit Shuffle.
This is intentional: the user can see what their steering produces
before committing. Tapping a row plays from that row and queues the
rest of the visible deck.

`tempo_band_chips.dart` (slice-4, used by `VibeBrowseScreen`)
becomes the inline content of the tempo dropdown menu — three
selectable band rows + an "Any tempo" reset row. `MoodChipRow`
(slice-4) is adapted to multi-select by lifting its single-
selected state into a `Set<MoodChip>` — confirmed safe because
Home's existing chip row is a separate consumer that keeps
single-select.

### 2.3 Radio-aware NowPlaying + entry points

`RadioBadge` and `SteerChipBar` stay in `NowPlayingScreen` but
become **conditional renders**: when no `RadioSession` is active,
both return `SizedBox.shrink()`. The widgets already accept
`session == null` cleanly today (per `radio_providers.dart`); the
patch is to short-circuit at the widget root instead of rendering
an invisible 0-height row that still consumes layout space.

When a session IS active they keep their slice-5 behaviour but
get a glass-pill restyle so they read as part of the wireframe
language. `RadioBadge` becomes a small `Glass(intensity: light)`
pill above the title strip; `SteerChipBar` becomes a horizontally-
scrolling glass chip strip above the scrubber.

**Three entry points feed the same `RadioSession`:**

| Entry point                                    | Seed                                        | Steering pre-load               |
|------------------------------------------------|---------------------------------------------|---------------------------------|
| Long-press track / album / artist (existing)   | the long-pressed entity                     | none                            |
| Songs tab Shuffle play with `[● Infinite]` ON  | most recently played track in the deck      | currently-selected MoodChip set |
| AI Compose finishes its generated playlist     | the LLM tracks (treated as a seed cluster)  | inferred from the LLM prompt    |

The Infinite toggle on the Songs tab sits next to the True Shuffle
toggle. When ON, the player watches the queue depth and calls
`radioSessionProvider.notifier.startFromTrack(...)` (or the new
`startFromCluster(...)` for path 3) when ~10 tracks remain.

**Steering control hand-off.** Two different chip widgets are
involved and the transition matters:

- **Pre-radio** — the user steers via the `MoodChipRow` (multi-
  select) inside the Songs tab. Selections drive `VibeShuffleQuery`
  for the deck.
- **At session start** — the radio session captures the current
  multi-select set as its initial steering vector via the chip-
  expression helper (§5).
- **In-flight** — once radio is active, the user steers via
  `SteerChipBar` rendered in NowPlaying (slice-5's locked 10-chip
  vocabulary, decay over ~10 picks). The Songs-tab chips no longer
  influence the live session — they belong to the deck-builder, not
  the radio. This is intentional: the user has navigated away from
  the Songs tab to be in NowPlaying, and slice-5's steering model
  is the authority while a session runs.

The AI Compose end-of-playlist sheet is a small additional UI:
bottom sheet with title, optional preview row, and a primary
"Keep playing" button that calls `startFromCluster`. Cancel returns
the user to the just-finished playlist.

`startFromCluster(List<Track>, {String? steeringHint})` is the one
new method on `RadioSessionNotifier`. Implementation:

1. Resolve each track to its embedding via the existing
   `PlaylistRepo.embeddingOf(int trackId)` port. Tracks whose
   `trackId` cannot be looked up (e.g. AI Compose tracks not in
   the library) are skipped.
2. Average the non-null embedding vectors element-wise into a
   single synthetic 1280-dim `Float32List`, then L2-normalize
   (matches the format `meanEmbeddingForAlbum` already returns).
   New helper `averageEmbeddings(List<Float32List>) → Float32List?`
   lives in `packages/playlist_engine/lib/src/radio_engine.dart`.
3. Feed the synthetic vector into `PlaylistRepo.knnByEmbedding(seed)`
   directly — the same kNN entry slice-5 already uses for the
   slice-5 seed paths. `RadioSession.start` reuses the resulting
   `KnnHit` candidate pool with no internal change.

If the cluster has no resolvable embeddings (e.g. AI Compose
generated names that aren't in the library), the method short-
circuits to "no seed" and the end-of-playlist sheet surfaces
the empty-cluster fallback message described in Risk #5.

### 2.4 Album-grouping bug fix (runtime, non-destructive)

The fix lives in `apps/mobile/lib/browse/album_view.dart`'s
`indexAlbums` function. Two-pass refactor:

**Pass 1 — collect album-artist hints.** Walk every track. For each
album title (case-insensitive trimmed), record the set of distinct
non-null `albumArtist` values. The "canonical album-artist" for a
title is the most frequent non-null value across that album's
tracks (ties broken by first-seen order to keep deterministic).

**Pass 2 — group.** Each track's group key:

```
if any track sharing the same album title has a non-null
albumArtist:
    use the canonical album-artist
else:
    use _normalizeArtist(track.artist ?? "")
```

`_normalizeArtist(String) → String` strips collaborator suffixes
case-insensitively and trims:

| Input                       | Output         |
|-----------------------------|----------------|
| `X feat. Y`                 | `X`            |
| `X ft. Y`                   | `X`            |
| `X featuring Y`             | `X`            |
| `X (with Y)`                | `X`            |
| `X (feat. Y)`               | `X`            |
| `X & Y`                     | `X & Y`        |
| `X, Y` (no separator hint)  | `X, Y`         |

Single-pass regex match — strips from the first marker onward, so
`X feat. Y feat. Z` becomes `X`. The U+2237 `∷` group separator
stays the same.

**Non-destructive guarantees:**

- `Track.albumArtist` is never mutated; the original tag value
  flows untouched into the queue, palette, and radio paths.
- The fix is a pure UI policy — the SQLite cache row, FLAC tag,
  and `track_meta` MBID resolution all stay verbatim.
- Hero tag `AlbumView.id` may shift between releases for affected
  albums (Risk #8); the underlying tracks do not.

### 2.5 Library sort + filter

The wireframe's Library header (`mobile-browse.jsx` lines 114-131)
shows two glass square buttons in the top-right next to the
"Library" title: a **grid/list toggle** and a **filter** button.
This slice wires both up and adds tab-aware sort/filter sheets.

```
┌────────────────────────────────────────────┐
│ Library              [grid/list]  [filter] │
│                                            │
│ [Albums]  Artists  Playlists  Songs        │
│                                            │
│   (album grid…)                            │
└────────────────────────────────────────────┘
```

**Per-tab options** — the filter sheet's contents change with the
active tab:

| Active tab | Sort options                                                   | Filter options                              |
|------------|-----------------------------------------------------------------|----------------------------------------------|
| Albums     | Title (default) / Artist / Year (newest) / Year (oldest) / Recently added | Genre (multi-select)                          |
| Artists    | Name (default) / Album count (most first) / Recently added       | Genre (multi-select)                          |
| Playlists  | Created date (newest, default) / Name                            | (none for slice 10)                           |
| Songs      | (controlled by vibe chips per §2.2)                              | (controlled by chip row + tempo dropdown)    |

**Null-tag handling for sort.** Albums missing the relevant tag
sort to the END of the visible list regardless of direction
(newest-first OR oldest-first), with a stable secondary sort on
title. Same rule for Artists missing album-count or recently-added
data. This avoids "Year (newest)" surfacing a wall of untagged
albums first.

The grid/list toggle:

| Tab      | grid view                          | list view                                       |
|----------|-------------------------------------|-------------------------------------------------|
| Albums   | 2-col tile grid (current)           | 1-col rows: small art + title + artist + count |
| Artists  | 3-col avatar grid (current)         | 1-col rows: avatar + name + tag                |
| Songs    | (n/a — list only)                   | (current)                                       |
| Playlists| (n/a — list only)                   | (current)                                       |

When the active tab is Songs or Playlists the toggle button is
rendered disabled (50% opacity, no tap target) so users see it
exists but understand it doesn't apply. Switching to Albums or
Artists re-enables it.

**Persistence.** All choices ride in `shared_preferences` so the
user's last selection sticks across launches. Keys:

- `library_view_albums` / `library_view_artists` — `grid` | `list`
- `library_sort_albums` / `library_sort_artists` / `library_sort_playlists` — enum string
- `library_filter_albums_genres` / `library_filter_artists_genres` — JSON-encoded `List<String>`

A new `libraryViewPrefsProvider` (Riverpod, async-init) loads
prefs once on first read, then exposes per-tab synchronous getters
+ setters that persist on every change.

**Genre options.** A new `genreOptionsProvider` derives the
distinct genre list from `tracks.genre` in `cache.db`. Values are
title-cased for display (e.g., `rock`, `Rock`, `ROCK` collapse to
`Rock`) but storage keys stay the original strings so the
underlying SQL `WHERE genre IN (...)` clause works on real tag
values. If the distinct count exceeds 50, the multi-select
dropdown gains an inline search field.

**Genre filter semantics.** Genres are tagged per-track, but the
filter applies to *album* and *artist* aggregates. An album passes
the filter if at least one of its tracks has a genre in the
selected set; an artist passes if any of their tracks does. Empty
selection = no filter (all rows pass). The OR-of-genres logic
matches user expectation ("show me anything that's Rock OR Jazz")
and avoids the empty-state trap of an AND query on multi-genre
albums.

**Filter sheet UI.** A glass bottom sheet (`Glass(intensity: heavy,
radius: 24)`) opened from the filter button; sections per tab,
with sort radio rows and filter dropdown chips. "Reset" button
clears all filters and resets sort to the default. "Done" closes
the sheet.

### 2.6 Test fix

`apps/mobile/test/widget_test.dart`'s "Gear icon reaches Settings
from every top-level tab" test is rewritten:

- Source of truth becomes `AppTab.values` rather than hard-coded
  route strings, so future tab additions update one place.
- Lookup switches from `find.text('Library')` (Material AppBar
  title) to `find.byTooltip('Settings')` (the gear `IconButton`
  carries it).
- The walk pumps each tab's route, verifies the gear is reachable,
  taps it, verifies `SettingsScreen` lands.

`settings_library` is grepped for any reference to retired routes
(`/queue`, `/now-playing`, `/random`, `/vibe`) — the queue route
stays valid (Now Playing overlay's bottom utility row pushes it),
the others become route push errors. The grep + cleanup lands in
the same change.

## 3. File-level changes

### 3.1 New

| File                                                       | Purpose                                                                |
|------------------------------------------------------------|------------------------------------------------------------------------|
| `apps/mobile/lib/widgets/discover_grids.dart`              | `DiscoverAlbumsGrid` + `DiscoverArtistsGrid`, refresh per section.     |
| `apps/mobile/lib/screens/songs_shuffle_tab.dart`           | The vibe-steered Songs tab body. Replaces `_SongsTab` in `library_screen.dart`. |
| `packages/core/lib/src/db/vibe_shuffle_query.dart`         | New SQL builder. Reuses `MoodQuery._querySpec`'s chip expressions.     |
| `apps/mobile/lib/widgets/end_of_playlist_sheet.dart`       | "Keep playing" sheet shown when AI Compose finishes its tracks.        |
| `apps/mobile/lib/providers/library_view_prefs.dart`        | Riverpod provider + `LibraryViewPrefs` value class + shared_preferences round-trip per tab. |
| `apps/mobile/lib/widgets/library_filter_sheet.dart`        | Glass bottom sheet with tab-aware sort + filter sections.              |
| `apps/mobile/lib/providers/genre_options_provider.dart`    | Derives the distinct, title-cased genre list from `tracks.genre`.      |

### 3.2 Modified

| File                                                       | Change                                                                 |
|------------------------------------------------------------|------------------------------------------------------------------------|
| `apps/mobile/lib/screens/home_screen.dart`                 | Drop `RadioHomeCard`; insert two discover grids between Featured and Artists rows. |
| `apps/mobile/lib/screens/library_screen.dart`              | Replace `_SongsTab` body with `SongsShuffleTab`; drop `Random` and `Vibe` sub-tabs (already done in the wireframe-shell pass; this slice deletes the dead routes). Add header sort/filter button + grid/list toggle next to "Library" title; pass tab-aware prefs into each sub-tab. |
| `apps/mobile/lib/browse/album_view.dart`                   | `indexAlbums` two-pass refactor for the feat./ALBUMARTIST grouping fix; add private `_normalizeArtist`. Sort callback parameterised so `_AlbumsTab` can supply Title / Artist / Year / Recently-added orderings. |
| `apps/mobile/lib/browse/artist_view.dart`                  | Sort callback parameterised so `_ArtistsTab` can supply Name / Album-count / Recently-added orderings. |
| `apps/mobile/lib/screens/now_playing_screen.dart`          | Conditional render guard on `RadioBadge` + `SteerChipBar`; restyle as glass pills. |
| `apps/mobile/lib/widgets/radio_badge.dart`                 | Glass-pill restyle. `session == null` → `SizedBox.shrink()`.           |
| `apps/mobile/lib/widgets/steer_chip_bar.dart`              | Glass-pill restyle. `session == null` → `SizedBox.shrink()`.           |
| `apps/mobile/lib/widgets/mood_chip_row.dart`               | Lift selection model to support multi-select via `MoodChipController`; default consumer (Home) keeps single-select. |
| `packages/core/lib/src/db/mood_query.dart`                 | Extract the per-chip SQL fragment into a public `String chipExpression(MoodChip)` helper so `VibeShuffleQuery` can reuse it without duplicating. Existing `MoodQuery.run` still calls it; behaviour byte-identical. |
| `apps/mobile/lib/providers/radio_providers.dart`           | Add `startFromCluster(List<Track>, {String? steeringHint})`.           |
| `packages/playlist_engine/lib/src/radio_engine.dart`       | Public helper `averageEmbeddings(List<Float32List>) → Float32List?` that L2-normalises the elementwise mean. |
| `apps/mobile/lib/app.dart`                                 | Drop `'/random'` and `'/vibe'` routes; keep `'/queue'`.                |
| `apps/mobile/lib/main.dart`                                | Pre-warm `libraryViewPrefsProvider.future` after `WidgetsFlutterBinding.ensureInitialized()` so the first Library build never paints unsorted/unfiltered. |
| `apps/mobile/test/widget_test.dart`                        | Rewrite the gear-icon walk against `AppTab.values` + `byTooltip`.      |

### 3.3 Retired

| File                                                       | Notes                                                                  |
|------------------------------------------------------------|------------------------------------------------------------------------|
| `apps/mobile/lib/screens/random_tab.dart`                  | Replaced by `discover_grids.dart`. Tests under `test/random_tab_test.dart` migrate. |
| `apps/mobile/lib/screens/vibe_browse_screen.dart`          | Replaced by `songs_shuffle_tab.dart`. Tempo / chip widgets it owned move with it. |
| `apps/mobile/lib/widgets/radio_home_card.dart`             | No longer rendered. Deleted, plus its test file.                       |
| `apps/mobile/lib/widgets/radio_seed_header.dart`           | Was the home-screen pill that re-entered a radio session. Same fate.   |

## 4. Data flow recap

```
Essentia indexer (.sonic.json) ──────────────────►  ingest service
                                                          │
                                                          ▼
                                                tracks table in cache.db
                                       (mood_*, bpm, danceability, voice_instrumental,
                                        status, added_at, embedding via vec0)
                                                          │
                              ┌───────────────────────────┼─────────────────────────────┐
                              ▼                           ▼                             ▼
                        MoodQuery                  VibeShuffleQuery                Radio kNN
                  (Home mood chips,                 (Songs shuffle deck)        (slice-5, unchanged
                   single-select)                     filter / bias /             vec0 MATCH)
                                                     true-shuffle                       │
                                                                                        │
                                                                    startFromCluster ◄──┘
```

## 5. Behavioural invariants (don't break these)

- Slice-4 mood SQL fragments are **immutable** in this slice. The new `VibeShuffleQuery` reuses
  the same per-chip composite expressions via the new public `chipExpression(MoodChip)` helper
  (which `MoodQuery._querySpec` now also calls). No threshold / weighting changes.
- Slice-5 `RadioSession` state machine is **immutable**. `startFromCluster` is a *new* entry
  point that resolves to the same internal `start(seed: …)` path with a precomputed average
  embedding.
- The `MoodChip` enum's locked order (`happy / sad / chill / energetic / focus`) is preserved
  in both the Home single-select chip row and the Songs multi-select chip row — slices 1–4
  widget tests assume this index.

## 6. Testing

- **`packages/core/test/vibe_shuffle_query_test.dart`** — new fixture with 6 tracks covering
  three chip strengths × three tempo bands. Verifies all three modes (filter / bias / true)
  return rows in the expected order.
- **`apps/mobile/test/songs_shuffle_tab_test.dart`** — pumps the tab with a fake repo,
  toggles chips, verifies (a) the deck list updates, (b) Shuffle Play loads the deck into
  the queue, (c) True Shuffle dims chips and routes to the random branch.
- **`apps/mobile/test/now_playing_radio_visibility_test.dart`** — verifies that with a null
  `radioSessionProvider`, neither widget appears in the tree; with an active session, both
  appear and tap targets work.
- **`apps/mobile/test/discover_grids_test.dart`** — migrated from `random_tab_test.dart`;
  asserts six tiles per grid + independent reseeds.
- **`apps/mobile/test/widget_test.dart`** — rewrite of the gear-icon walk per §2.6.
- **`apps/mobile/test/radio_cluster_seed_test.dart`** — new: when AI Compose's playlist finishes
  and the user taps "Keep playing", the resulting `RadioSession` reports the playlist tracks
  as its seed cluster and the steering hint propagates.
- **`apps/mobile/test/album_grouping_test.dart`** — three cases:
  1. 9 tracks tagged `albumArtist=X`, 1 track `artist="X feat. Y"` + null albumArtist → all
     10 group as a single album under canonical "X".
  2. No `albumArtist` anywhere; tracks split between `"X"` and `"X feat. Y"` → both
     normalise to `"X"` and group together.
  3. `_normalizeArtist` round-trips: feat./ft./featuring/with all strip; `&` and `,`
     do not.
- **`apps/mobile/test/library_view_prefs_test.dart`** — `LibraryViewPrefs` round-trips
  through shared_preferences for sort / filter / view-mode; defaults apply on first launch.
- **`apps/mobile/test/library_sort_filter_test.dart`** — drives the Library shell:
  (a) opens filter sheet, picks "Year (newest first)" → grid reorders;
  (b) selects two genres → grid filters to albums whose tracks include those genres;
  (c) toggles grid/list → layout changes;
  (d) all three persist across a `pumpWidget` rebuild.

## 7. Risk register (slice 10)

| # | Risk                                                                                          | Mitigation                                                                                            |
|---|------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| 1 | Multi-select mood chip controller breaks Home's existing single-select consumer.               | The lift is purely additive: `MoodChipController.single()` and `.multi()` constructors. Home uses `.single()`; Songs uses `.multi()`. Existing widget tests bind on the chip's tap, not on the controller mode. |
| 2 | Bias-mode SQL produces empty results when all selected chips have zero composite scores library-wide (e.g. user picks Sad + Focus, library is all upbeat). | The query is already permissive (`WHERE Σ > 0`); when it returns 0 rows the UI shows an empty-state with "Pick fewer chips or try True Shuffle" instead of silently widening the query or shuffling everything. The user keeps control of the steering. |
| 3 | Songs deck refreshes faster than the user can read on a 5k-track library.                     | Query is debounced 250 ms after the last chip / tempo change. The deck list does not animate row positions to avoid jitter. |
| 4 | Infinite radio kicks in mid-listen and the user didn't mean to enable it.                     | Toggle is sticky (persisted to `shared_preferences`) but ALWAYS surfaces a one-time toast on first activation each session: "Infinite radio on — pulling more after this deck." |
| 5 | `startFromCluster` sees an empty resolvable cluster (e.g. AI playlist tracks not yet ingested). | The averaging step in §2.3 already skips tracks with null embeddings, so a partially-resolvable cluster works fine (one embedding still averages to itself). When ZERO tracks resolve, `averageEmbeddings` returns `null` and `startFromCluster` short-circuits without calling `RadioSession.start`; the end-of-playlist sheet surfaces "Can't extend this playlist yet — re-ingest pending" instead of the success state. The user's just-finished playlist remains the active queue. |
| 6 | Glass restyle of `RadioBadge` / `SteerChipBar` clashes with the player aurora's dominant tint. | Glass `tint: palette.dominant` already supported; both widgets adopt it the same way the metadata strip does. |
| 7 | `RadioHomeCard` / `RadioSeedHeader` deletion orphans deep-link entry points slice-5 documented. | Slice-5 docs note both as discoverability aids only. The long-press path remains canonical. Update slice-5 spec note if it doesn't already point at long-press as the entry. |
| 8 | Album grouping fix re-keys `AlbumView.id` between releases — old hero animations were keyed on the buggy id, would break detail-screen flights for in-flight users. | The id derives from `(albumArtist ∷ album)`; when canonical resolution shifts, the id shifts. Mitigation: the album-detail back-stack is route-popped before `indexAlbums` re-runs on the first launch after the fix lands — the implementation gates on a `shared_preferences` flag (`album_grouping_v2_applied`) so no in-flight Hero ever observes the id transition. After the gate flips, all subsequent flights see a stable id. |
| 9 | `shared_preferences` read on first build returns null → tab renders unsorted/unfiltered for one frame. | `LibraryViewPrefs` has compile-time defaults; first build reads from a `Future` pre-warmed in `main.dart`'s startup sequence (after `WidgetsFlutterBinding.ensureInitialized()`, before `runApp`). The default applies if the warm-up hasn't completed. |
| 10 | Genre dropdown shows hundreds of unique values for messily-tagged libraries (e.g., `"Rock"`, `"rock"`, `"ROCK"` distinct). | Display values title-case + dedupe; storage keys retain original tag strings so the SQL `WHERE genre IN (...)` clause matches the cache rows. After normalisation a 100-track library should produce <30 genres; if distinct count >50 the dropdown gains an inline search field. |
| 11 | Filter sheet open while user pivots tabs — sheet shows stale tab's options. | Sheet listens to `DefaultTabController.indexIsChangingNotifier`; when a tab change starts it dismisses itself. The user re-taps the filter button on the new tab. |

## 8. Verification matrix

| # | Scenario                                                                                                                                                                              | Expected                                                                                                              |
|---|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| 1 | Open Home with a 200-track ingested library. Tap "Discover albums" refresh. Tap "Discover artists" refresh.                                                                            | Each grid reseeds independently; the un-tapped grid keeps its tiles.                                                  |
| 2 | Library → Songs. No chips. Tap Shuffle.                                                                                                                                                | Plays a uniformly-random track; queue fills with random next picks.                                                   |
| 3 | Library → Songs. Pick "Chill". Deck list updates. Tap Shuffle.                                                                                                                          | Deck is filtered to `mood_relaxed * tempo factor > 0.5`; tracks play in random order from that deck.                  |
| 4 | Library → Songs. Pick "Chill" + "Focus". Deck list updates.                                                                                                                            | Deck is ranked by `(chill_expr + focus_expr) × recency`; longer than single-chip filter, never empty for a non-trivial library. |
| 5 | Library → Songs. True Shuffle ON, chips selected.                                                                                                                                       | Chips dim; deck list switches to a random sample; Shuffle plays from random sample.                                   |
| 6 | Long-press a track → Start radio.                                                                                                                                                       | RadioBadge appears in NowPlaying. SteerChipBar appears above scrubber.                                                |
| 7 | NowPlaying with no radio session.                                                                                                                                                       | Neither RadioBadge nor SteerChipBar render (tree shows neither widget; no 0-height stub).                             |
| 8 | Library → Songs. Toggle Infinite ON. Pick "Energetic". Tap Shuffle. Let queue drain to ~10.                                                                                             | Radio kicks in. RadioBadge appears. SteerChipBar pre-fills with Energetic.                                            |
| 9 | AI Compose: prompt "rainy Sunday jazz" → 6 tracks generated. Let them play through.                                                                                                     | End-of-playlist sheet appears: "Keep playing?" → tap → radio session starts seeded by the 6 tracks; mood inferred.    |
| 10 | `flutter test apps/mobile`.                                                                                                                                                           | All tests pass, including the rewritten gear-icon walk.                                                              |
| 11 | Library with a 10-track release where 1 track is `"Artist X feat. Y"` and `albumArtist=null`, the other 9 are tagged `albumArtist="X"`. Open Library → Albums.                          | All 10 tracks group into one album under "X". Album-detail screen shows all 10 tracks.                              |
| 12 | Library with a release where NO track has `albumArtist`; tracks split between `"X"` and `"X feat. Y"`.                                                                                  | Tracks normalise via `_normalizeArtist` and group together as "X".                                                  |
| 13 | Library → Albums. Tap filter button → "Year (newest first)" → Done. Force-quit and reopen.                                                                                              | Albums sort by year DESC. Sort sticks across restart.                                                               |
| 14 | Library → Albums. Tap filter button → select genres "Rock" + "Jazz" → Done.                                                                                                             | Grid shows only albums with at least one track tagged Rock or Jazz. Filter persists across restart.                 |
| 15 | Library → Albums. Tap grid/list toggle.                                                                                                                                                  | Layout switches to one-column rows with small art + title + artist + track count. Setting persists across restart. |
| 16 | Library with 80 distinct genre tags after normalisation.                                                                                                                                | Filter sheet's genre dropdown gains an inline search field.                                                         |

## 9. Out of scope

- Genre / decade chips on the Songs tab — slice-4's classifier exposes genre top-3 but
  the UI surface is large enough; revisit in a future slice if power users ask.
- Per-album mood badges — would let Library → Albums show "this album is mostly Chill",
  but adds rendering cost on every tile. Not in this slice.
- Server-side or cloud sync of recent radio seeds — slice-9 cast already pushes audio,
  but radio re-entry stays device-local.
- LLM-driven steering on the Songs tab — the chips are deterministic SQL today; LLM
  can rewrite the chip selections from natural language in a later slice without
  changing the underlying query layer.
