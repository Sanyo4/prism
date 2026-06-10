# Slice-11 — Pivot to mood-shuffle-radio

## Context

After slice-10b/c/d on-device testing, the user proposed a design pivot: retire the AI Compose / Mood-as-page surfaces and re-center the app around the **Songs tab as a smart shuffle** (multi-select mood filters → deck) and **radio as infinite-from-this-track**. Five user-reported bugs from slice-10d are folded into this slice as Wave 1 since the pivot makes radio + the long-press affordances *more* central, not less.

**The thesis.** A music player is a vibe, not a workflow. AI Compose was always "write a prompt → wait for an LLM call → see a playlist" — that's a chatbot wearing a player skin. The iPod Shuffle's magic was instant — no menus, no prompts, just music that fits. Slice-11 returns the app to that primitive: pick chips, hit shuffle, long-press a track to launch infinite radio from it.

**Decisions taken before planning:**
- AI tab is retired entirely. NewVibeSheet, ComposeCard, MoodResultsScreen, PlaylistDetailScreen, and the slice-10b `playlists` cache.db v2 table go with it (the table stays as a no-op — no schema bump).
- Radio gains a `temperature` knob — top-K sampling with weight ∝ 1/distance. Same seed → different radio every launch. Slice-5's `RadioSession` state machine surface stays byte-identical; only `RadioEngine.next` adds the sampler.
- Songs tab moves from a niche "shuffle composite" to **the** primary surface. Bottom nav reorders.
- The slice-10d boot ingest (live `tracks` table populated on launch) stays — it's the precondition for everything else working.

## Sequencing

Wave 1 first so the app is *usable* while the rest of the pivot lands. Wave 2 builds the new center of gravity. Wave 3 retires the dead surfaces. Wave 4 ships.

```
Wave 1 — bug fixes (lands first, restores broken functionality)
  A1  Radio "nothing happens" — diagnose + fix
  A2  Album detail layout — drop scrim, title in metadata box, tappable artist
  A3  Artist detail — AuroraBackground wrap (light theme)

Wave 2 — new center
  B1  Restore 3-tile long-press sheet (Play Next | Add to Queue | Start Radio)
  B2  Songs tab multi-select mood filters (chips actually constrain the deck)
  B3  Radio randomness (top-K weighted sampling + temperature knob)

Wave 3 — retirement + repurpose
  C1  Retire AI tab + MoodResultsScreen + NewVibeSheet + PlaylistDetailScreen + ComposeCard
  C2  Home repurpose — drop mood chips, add recently-added grid
  C3  Bottom nav reorder — Songs promotes, AI slot removed

Wave 4 — ship
  D1  Final analyze + full-test sweep
  D2  Commit + push
  D3  APK build + on-device install
  D4  On-device verification checklist
```

Each wave ends in a commit boundary. Wave 1 is independent. Wave 2's B1 depends on A2 (sheet replaces single-tile slice-10d radio sheet). B2 depends on B1 (deck rows use the new sheet). B3 is independent. Wave 3's C1 depends on B2 (Songs tab is the new mood entry point — MoodResultsScreen must die *after* its replacement is wired). C2 + C3 land with C1.

## Locked invariants

Same as slice-10b:
- Slice-4 mood SQL byte-identical (`MoodQuery.chipExpression` strings stay).
- Slice-5 `RadioSession` state machine surface byte-identical; **B3 adds top-K sampling inside `RadioEngine.next` only — public API unchanged**.
- Slice-7 theme tokens (`packages/ui/`) consumed only.
- `MoodChip` enum order + `SteerChipBar.visualOrder` preserved.
- Slice-10b boot ingest (`bootIngestProvider`) preserved — it's the precondition for non-empty deck / radio.

New for slice-11:
- `cache.db` v2 `playlists` + `playlist_tracks` tables stay defined (migration not reverted) but no longer written. Future slice can repurpose for "saved radio sessions" or remove via v4.
- AI tab route slot in `AppShell` removed entirely; bottom nav drops from 4 → 3 tabs (Home / Search / Library) plus a promoted Songs entry.
- `Track.albumArtist` still never mutated (slice-10 §2.4 invariant).

---

## Wave 1 — Bug fixes

### A1. Radio "nothing happens" — diagnose + fix

**Symptom:** User long-presses a track, sees the radio context sheet, taps "Start radio from this track", "Radio started" snackbar appears, but nothing actually plays. Slice-10d's boot ingest fixed the *symptom* of zero ready tracks; A1 fixes whatever's broken downstream.

**Diagnosis path:** Trace `radioSessionProvider.startFromTrack(track)`:
1. Does the seed track have an embedding? (`SELECT 1 FROM track_embeddings WHERE track_id=?`) If vec0 is degraded, kNN returns empty → radio session "starts" but has no tracks.
2. Does `RadioEngine.next` actually return tracks? (`PlaylistRepoImpl.knnByEmbedding` results.)
3. Is `queueProvider.notifier.loadContext(...)` called with the radio tracks?
4. Is `playbackServiceProvider.play()` actually called?

**Likely root causes (ranked):**
1. **Vec0 degraded mode** still active on device — slice-10c rebuild + slice-10b A1 fallback combined to "open succeeds but kNN returns empty". `Vec0Loader.loadFailed=true` would silently produce empty radio.
2. **Embeddings table empty** — boot ingest may fire `IngestController.rescan()` but if `track_embeddings` writes fail (because the table doesn't exist when vec0 isn't loaded — slice-10c moved the DDL to post-open), no embeddings = no kNN.
3. **Queue.loadContext not called** — `RadioSession` updates state but the playback queue isn't told. Less likely but possible.

**Investigation step (do this first):** Add a single `print` at `RadioEngine.next` start + end logging tracksIn / tracksOut counts. Re-install, long-press a track, capture `adb logcat | grep RadioEngine`.

**Fix scope:**
- If embeddings table missing → make the slice-10c post-open DDL guarantee the table exists (`CREATE VIRTUAL TABLE IF NOT EXISTS`) AND make ingest skip embedding writes gracefully when vec0 is degraded but log a clear `Vec0Loader.loadFailureMessage`.
- If kNN returns empty for a valid seed → add a diagnostic surface (Settings → Library shows `embeddings_indexed=N` count alongside `ready=N`).
- If queue.loadContext isn't called → fix the radio→queue handoff in `radioSessionProvider`.

### A2. Album detail layout — drop scrim, title in metadata box, tappable artist

**User feedback:** "the blur on the album text looks bad and hard to read, maybe move it above the artist in the same box area. i would like to click on the artist name and it should take me to the artist page."

**Files:**
- Modify: `apps/mobile/lib/screens/album_detail_screen.dart`
  - **Drop the `FlexibleSpaceBar.title` overlay AND the `BackdropFilter` scrim** introduced in slice-10b §A4. Cover art is just cover art — no overlay, no blur.
  - **Move the title to the top of the metadata Glass card.** New stack inside the card's `Expanded` left column: `[title (titleLarge, w600)] → [artist (body16, w600, tappable)] → [year · trackCount caption]`.
  - **Wrap the artist `Text` in a `GestureDetector(onTap: () => Navigator.push(ArtistDetailScreen.route(artist)))`** — pushes the existing artist detail screen. Use a tap-target larger than the text via `behavior: HitTestBehavior.opaque` + `MouseRegion(cursor: SystemMouseCursors.click)` so the affordance is discoverable.
  - The Play / Shuffle / Heart action stack on the right of the card stays put (slice-10b §A4).
- Update: `apps/mobile/test/album_detail_test.dart` — drop the `BackdropFilter` ancestor assertion; add an assertion that the metadata Glass card contains the album title `Text` AND that the artist `Text` is wrapped in a `GestureDetector` whose `onTap` pushes a route matching `/artist/...`.

**Reuse:** `Glass` from `prism_ui`; `ArtistDetailScreen.route(artist)` already exists (used by Library Artists tab tap).

### A3. Artist detail — AuroraBackground wrap (light theme)

**User feedback:** "the artist page is still in dark mode."

**Root cause:** Slice-10b §A3 wrapped `SettingsScreen` and `MoodResultsScreen` in `AuroraBackground` (cream backdrop, transparent Scaffold) but missed `ArtistDetailScreen`. With `themeMode: ThemeMode.light` locked at the MaterialApp level the *colours* are right, but without the AuroraBackground the cream gradient backdrop is missing — looks "darker than the rest of the app".

**Files:**
- Modify: `apps/mobile/lib/screens/artist_detail_screen.dart` — wrap the `Scaffold` body in `AuroraBackground(variant: AuroraVariant.library, child: ...)` and set `Scaffold.backgroundColor: Colors.transparent`.
- Update: existing artist detail tests, if any.

**Reuse:** `AuroraBackground` + `AuroraVariant.library` already exist.

---

## Wave 2 — New center

### B1. Restore 3-tile long-press sheet

**User feedback:** "i cant add tracks to queue nor next up via long pressing or swiping."

**Slice-10d regression:** Slice-10d replaced the slice-1 three-tile sheet (Play Next / Add to Queue / Start Radio) with a single-tile radio sheet (`RadioContextSheet`). Bringing back the queue-management actions while keeping radio as a third tile.

**Files:**
- Modify: `apps/mobile/lib/screens/radio_context_sheet.dart` — extend the sheet body from one tile to three:
  1. **Play Next** (icon `Icons.playlist_play`) — calls `ref.read(queueProvider.notifier).playNext([track])`.
  2. **Add to Queue** (icon `Icons.queue_music`) — calls `ref.read(queueProvider.notifier).addToQueue([track])`.
  3. **Start Radio** (icon `Icons.radio_outlined`) — existing track-only flow.
  - Each tile dismisses the sheet + shows a snackbar (`'Added to Play Next'`, `'Added to Queue'`, `'Radio started'`).
  - Drop the debug-only `assert(seed is TrackSeed)` since the sheet now does more than radio. Sheet always opens for a track; non-track seeds still no-op (defence in depth).
- Modify: every long-press call site from slice-10d (album_detail, artist_detail, songs_shuffle_tab, queue_screen, now_playing_screen, playlist_detail) — same call, sheet now offers 3 tiles instead of 1.
- Test: extend `apps/mobile/test/long_press_radio_test.dart` to assert all three tiles render + dispatch correctly.

**Reuse:** `queueProvider.notifier.playNext` and `addToQueue` exist (slice-1).

### B2. Songs tab multi-select mood filters

**User feedback:** "on the song tab all tracks would be loaded and (like ipod shuffle) and i can filter based on the mood chips? kind of like a super shuffle using the data from the sonic analysis?"

**Current state (slice-10d §D consolidation):** Songs tab uses `MoodChipController.single` after the slice-10d push pivot — chips push to `MoodResultsScreen` (which is being retired in C1). Multi-select chip → deck filter wiring needs to be reinstated **correctly** this time (the slice-10b D wiring had a True-Shuffle bypass bug).

**Files:**
- Modify: `apps/mobile/lib/screens/songs_shuffle_tab.dart` — restore `MoodChipController.multi(initial: state.chips, onChanged: ...)`. Drop the slice-10d single-select push (pushes to `MoodResultsScreen` which is going away). Keep the rest of the layout (tempo dropdown, True-Shuffle toggle, "Pick a vibe" header, "Shuffle play" button, deck list).
- Modify: `apps/mobile/lib/providers/songs_shuffle_providers.dart` — restore the `chips: Set<MoodChip>` field on `SongsShuffleState` and the `setChips` method on the notifier.
- Modify: `apps/mobile/lib/db/vibe_shuffle.dart` (or wherever the deck query lives) — the deck query must apply the chip filter under **both** True-Shuffle AND Tempo modes. The slice-4 `VibeShuffleQuery` already accepts a chip set; ensure both branches in `shuffleDeckProvider` pass the user's chip selection through.
- Modify: `apps/mobile/lib/widgets/mood_chip_row.dart` — no change; `.multi` mode already exists.
- Test: `apps/mobile/test/songs_shuffle_tab_test.dart` — assert that toggling a chip rebuilds the deck with the chip in the query (both True-Shuffle and Tempo modes).

**Reuse:** `MoodChipController.multi` already exists; `VibeShuffleQuery` already accepts chips.

### B3. Radio randomness — top-K weighted sampling + temperature

**User feedback:** "the radio is esentialy infitate mode and it would also need a bit of randomness so the radio isnt the same every time for each track start."

**Files:**
- Modify: `packages/playlist_engine/lib/radio_engine.dart` — `RadioEngine.next(...)`:
  - Today: returns top-K nearest neighbours by cosine distance, deterministic.
  - New: pull top-N (where N = K × `temperatureMultiplier`, e.g. K=20 → N=80), then sample K from N with weight ∝ `1 / (distance + ε)`. Ties broken by `Random` (seeded by `DateTime.now().microsecondsSinceEpoch` so same seed in same second is deterministic for tests).
  - Add a `RadioEngineConfig({double temperature = 0.4, int topNMultiplier = 4, ...})` parameter so the temperature is tunable from a settings surface later.
- Modify: `packages/playlist_engine/lib/radio_session.dart` — pass `RadioEngineConfig` through `RadioSession.start*` constructors. Default config = `temperature: 0.4`. Slice-5 state machine surface unchanged.
- Test: `packages/playlist_engine/test/radio_engine_test.dart` — extend to assert:
  1. Same seed at two different `Random.seed` values produces different radio tracks (probabilistic — assert ≥3 of 20 tracks differ).
  2. With `temperature: 0.0` the engine reverts to deterministic top-K (regression guard).
  3. Top-N pool is bounded (no unbounded sampling that would slow down on huge libraries).

**Reuse:** Existing `knnByEmbedding` returns ordered results — just request a larger N and sample K from it.

---

## Wave 3 — Retirement + repurpose

### C1. Retire AI tab + MoodResultsScreen + NewVibeSheet + PlaylistDetailScreen

**Files (deletions):**
- Delete: `apps/mobile/lib/screens/ai_tab.dart`
- Delete: `apps/mobile/lib/screens/mood_results_screen.dart`
- Delete: `apps/mobile/lib/screens/new_vibe.dart`
- Delete: `apps/mobile/lib/screens/playlist_detail_screen.dart`
- Delete: `apps/mobile/lib/widgets/compose_card.dart`
- Delete: `apps/mobile/lib/widgets/playlist_result_card.dart` (used by NewVibeSheet)
- Delete: `apps/mobile/lib/providers/playlists_provider.dart`
- Delete: `apps/mobile/lib/providers/ai_compose_playback_providers.dart` (state for "AI playback active" — no longer relevant)
- Delete: `apps/mobile/lib/widgets/end_of_playlist_sheet.dart` (was driven by AI compose end-of-queue)
- Delete (tests): `apps/mobile/test/ai_tab_test.dart`, `apps/mobile/test/playlists_tab_test.dart`, anything referencing deleted widgets.

**Files (modifications):**
- Modify: `apps/mobile/lib/app.dart` — drop `aiRoute`, `NewVibeSheet.routeName`, the AI compose end-of-queue listener block (lines ~46-79), and any imports.
- Modify: `apps/mobile/lib/shell/app_shell.dart` — drop `aiRoute` from `bottomNavTabs`.
- Modify: `apps/mobile/lib/screens/library_screen.dart` — replace `_PlaylistsTab` body (currently reads `playlistsProvider`) with a placeholder `'Library playlists coming back in a future slice'` Card OR remove the Playlists tab from the TabBar entirely.
- Modify: `apps/mobile/lib/widgets/playlist_result_card.dart` consumers — none after deletion.

**Note:** `cache.db` v2 `playlists` + `playlist_tracks` tables stay defined. No migration revert. The data is just unreferenced.

**Reuse:** N/A — pure deletion + a few rewires.

### C2. Home repurpose — drop mood chips, add recently-added grid

**Files:**
- Modify: `apps/mobile/lib/screens/home_screen.dart` —
  - Drop the `MoodChipRow()` — its single-select push target (`MoodResultsScreen`) is gone.
  - Drop the `_ComposeCard` — moving to Songs tab as the primary surface for "make me a vibe".
  - Keep `_RecentlyPlayedGrid` and add a new `_RecentlyAddedGrid` below it (sorted by `Track.dateAdded` desc, top 6 albums).
  - Greeting + recents-only Home matches a pure listening surface.
- Modify: `apps/mobile/lib/providers/library_providers.dart` (or new `recently_added_provider.dart`) — `recentlyAddedAlbumsProvider` derives from `albumsProvider` + sort by max(`Track.dateAdded`) per group.

**Reuse:** Existing `albumsProvider` derivation; `_RecentlyPlayedGrid` shape.

### C3. Bottom nav reorder

**Files:**
- Modify: `apps/mobile/lib/shell/app_shell.dart` — bottom nav becomes 4 tabs in this order: **Songs · Home · Search · Library**.
  - Songs as the leftmost tab (the iPod-shuffle pivot's primary affordance).
  - Library still has Albums / Artists / (placeholder) Playlists tabs.
  - The "AI" / "Create" tab removed entirely.
- Modify: `apps/mobile/lib/screens/songs_shuffle_tab.dart` — promote from a tab inside Library to a top-level screen. Add an `AppBar` (matching the Home/Search/Library AppBar pattern). The screen path becomes `/songs`.
- Modify: `apps/mobile/lib/screens/library_screen.dart` — drop the Songs tab from the inner TabBar (Albums / Artists / Playlists remain). Library stays a 3-tab screen.

**Reuse:** Existing `AppShell.bottomNavTabs` shape.

---

## Wave 4 — Ship

### D1. Final analyze + full-test sweep

```
flutter analyze                  # 0 issues
cd packages/core && dart test    # all pass
cd packages/playlist_engine && dart test  # +new radio randomness tests
cd packages/playback && flutter test       # all pass
cd apps/mobile && flutter test             # all pass; slice-10d AI tests deleted
```

### D2. Commit + push

One commit per wave letter (A, B, C, D). Final commit boundary: D2 = push to `feature/slice-01-scaffold-scan-play-queue`.

### D3. APK build + on-device install

```
flutter build apk --release                 # ~10-15 min
flutter install --release -d 47291FDKD000C3 # Pixel 9 Pro Fold
```

### D4. On-device verification checklist

1. **Radio actually plays.** Long-press any track → Start Radio → music starts within 2s, queue is populated with ~30 similar tracks.
2. **Radio randomness.** Long-press the same track twice in a row → the resulting queue has ≥30% different tracks.
3. **Long-press sheet has three tiles.** Play Next / Add to Queue / Start Radio. Each works.
4. **Album detail.** Title is in the metadata Glass card (not overlaid on cover). Artist name is tappable → ArtistDetailScreen pushes.
5. **Artist detail.** Cream backdrop matches the rest of the app (no dark mode).
6. **Songs tab is primary nav.** Bottom nav: Songs / Home / Search / Library.
7. **Songs tab chips filter.** Multi-select Happy + Energetic → deck reflows to high-mood-score tracks. Toggle one off → deck reflows back.
8. **Home is calm.** No Compose card, no mood chips, just recents.
9. **AI tab is gone.** No fourth bottom nav slot for "Create".
10. **Cold-start ingest.** First launch after reboot — Library populates within 2s; no "zero ready tracks" error.

---

## Deferred (out of slice-11 scope)

| Item | Reason | Future slice |
|------|--------|--------------|
| Repurpose `playlists` table for "saved radio sessions" | Need UX design for the saved-session surface; v2 table stays as no-op for now | slice-12 |
| Tunable temperature in Settings | Default 0.4 is a reasonable middle; expose UI later | slice-12 |
| Dark theme | Cream-light is the locked aesthetic for now | slice-13+ |
| Library favourites system | Heart on album detail still placeholder | slice-12 |
| `RadioHomeCard` / recent-seeds surface | Removed in pivot; long-press track is the canonical entry | slice-12+ |

---

## Critical files (quick reference)

```
# Wave 1
apps/mobile/lib/screens/album_detail_screen.dart    # A2: scrim drop, title in card, tappable artist
apps/mobile/lib/screens/artist_detail_screen.dart   # A3: AuroraBackground wrap
packages/core/lib/src/db/cache_db.dart              # A1 maybe: post-open DDL guard
packages/core/lib/src/db/vec_loader.dart            # A1 maybe: better degraded surface
apps/mobile/lib/providers/radio_providers.dart      # A1: queue.loadContext handoff trace
packages/playlist_engine/lib/radio_engine.dart      # A1: empty kNN diag

# Wave 2
apps/mobile/lib/screens/radio_context_sheet.dart    # B1: 3 tiles
apps/mobile/lib/screens/songs_shuffle_tab.dart      # B2: multi-select chips
apps/mobile/lib/providers/songs_shuffle_providers.dart  # B2: chips field restored
packages/playlist_engine/lib/radio_engine.dart      # B3: top-K weighted sampler
packages/playlist_engine/lib/radio_session.dart     # B3: RadioEngineConfig pass-through

# Wave 3 (deletions)
apps/mobile/lib/screens/ai_tab.dart                 # DELETE
apps/mobile/lib/screens/mood_results_screen.dart    # DELETE
apps/mobile/lib/screens/new_vibe.dart               # DELETE
apps/mobile/lib/screens/playlist_detail_screen.dart # DELETE
apps/mobile/lib/widgets/compose_card.dart           # DELETE
apps/mobile/lib/widgets/playlist_result_card.dart   # DELETE
apps/mobile/lib/widgets/end_of_playlist_sheet.dart  # DELETE
apps/mobile/lib/providers/playlists_provider.dart   # DELETE
apps/mobile/lib/providers/ai_compose_playback_providers.dart  # DELETE
apps/mobile/test/ai_tab_test.dart                   # DELETE
apps/mobile/test/playlists_tab_test.dart            # DELETE

# Wave 3 (modifications)
apps/mobile/lib/app.dart                            # C1: drop AI route + listener; C3: Songs route
apps/mobile/lib/shell/app_shell.dart                # C3: bottom nav reorder
apps/mobile/lib/screens/home_screen.dart            # C2: drop mood chips + ComposeCard, add recently-added
apps/mobile/lib/screens/library_screen.dart         # C1: Playlists placeholder; C3: drop Songs tab
apps/mobile/lib/screens/songs_shuffle_tab.dart      # C3: promote to top-level
```

## Existing utilities reused

- `MoodChipController.multi` (`apps/mobile/lib/widgets/mood_chip_row.dart`) — B2
- `VibeShuffleQuery` (`packages/core/lib/src/db/vibe_shuffle.dart`) — B2 chip filter pass-through
- `queueProvider.notifier.playNext / addToQueue` (slice-1) — B1 sheet tiles
- `RadioSession.start*` (`packages/playlist_engine/lib/radio_session.dart`) — B3 config plumbing
- `knnByEmbedding` (`packages/core/lib/src/db/playlist_repo_impl.dart`) — B3 top-N pull
- `AuroraBackground` (`packages/ui/lib/aurora_background.dart`) — A3
- `Glass` / `GlassIntensity` (`packages/ui/lib/glass.dart`) — A2 metadata card
- `ArtistDetailScreen.route` — A2 tappable artist
- `bootIngestProvider` (slice-10d) — preserved precondition
