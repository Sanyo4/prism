# Slice 1 — Scaffold, scan, play, queue, `AppShell` + Settings gear

## 1. Context

Slice 1 lays the ground for every later slice: a Melos-managed Flutter
monorepo, an `AppShell` that every top-level route renders inside, a
cancelable filesystem scanner that emits `Track` records from audio
tags, a `just_audio` + `audio_service` playback layer with gapless
transitions and tag-based ReplayGain, and a three-zone queue
(Upcoming / PlayNext / History) backed by a single
`ConcatenatingAudioSource`. The result is a music player that scans a
folder, lists tracks, plays them with OS-level media controls, respects
ReplayGain tags, and exposes a placeholder Settings surface reachable
from any top-level screen. It assumes a greenfield tree, Flutter stable
installed locally, a Pixel 9 Pro Fold for Android runtime verification,
and a Linux laptop for desktop verification. Sidecar files, online
metadata, theming polish, and LLM backends arrive in later slices.

## 2. Goals / Non-goals

**Goals**

- Melos workspace with `apps/mobile`, `packages/core`, `packages/playback`.
  Path deps: `apps/mobile` → `packages/playback` → `packages/core`.
- `AppShell` with a top-right gear opening `SettingsScreen`; the screen
  has placeholder `Library` and `Playback` section headers only
  (later slices append rows).
- `LibraryScanner` (`packages/core`): async generator walking a
  configured directory, reading tags via `audiotags`, yielding `Track`
  records; cancelable via a `CancellationToken`.
- `PlaybackService` (`packages/playback`): wraps `just_audio` +
  `audio_service`; gapless via `ConcatenatingAudioSource`; applies
  ReplayGain from tag-embedded `REPLAYGAIN_TRACK_GAIN` /
  `REPLAYGAIN_ALBUM_GAIN`, flat (0 dB) otherwise.
- `QueueService`: three zones (Upcoming / PlayNext / History) projected
  into one `ConcatenatingAudioSource`; API `playNext(Track)`,
  `addToUpcoming(Track)`, `move(from, to)`, `clearPlayNext()`.
- UI: `TracksScreen` (flat list, tap-to-play), `NowPlayingScreen`
  (scrub + transport), `QueueScreen` (three sections with headers).
- Android lockscreen / notification transport via `audio_service`.
- Linux desktop build runs, plays audio, honors MPRIS where routed.

**Non-goals**

- Album / Artist / Genre browse, MusicBrainz / CAA / Last.fm, Random tab
  (slice 2).
- `.sonic.json` sidecars, SQLite cache, vector index, mood browse
  (slice 4).
- `packages/playlist_engine` or any LLM-backed flow (slices 5, 6, 8).
- Essentia Python indexer (slice 3).
- Apple Music visual polish, adaptive palette, hero transitions,
  custom typography (slice 7). Slice 1 ships Material 3 baseline.
- DLNA / Chromecast push (slice 9).
- Equalizer or DSP beyond ReplayGain volume scaling.
- Measured (Essentia) ReplayGain — only tag-embedded values.
- Gesture drag-handle queue reorder (slice 7 adds it); slice 1 ships
  `Move up` / `Move down` menu items.

## 3. Dependencies

Depends on: —
Unblocks: 2, 3, 4, 5, 6, 7, 8, 9

## 4. Docs to refresh

Run the listed commands before writing any Dart code. Keep a ≤5-line
"API summary" note per package in a scratch file — the point is to
catch API drift from training data before it hits the keyboard.

### Flutter (stable channel)

- `WebFetch https://docs.flutter.dev/release/release-notes` — current
  stable version, breaking changes.
- `WebFetch https://api.flutter.dev/flutter/material/MaterialApp-class.html`
  — `MaterialApp` constructor surface.

**API summary reminder:** Material 3 is the default. Slice 1 uses
`MaterialApp` + Navigator 1.0 (three screens don't justify a router
package). Leave theming on defaults; slice 7 re-derives theme.

### `just_audio`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "just_audio"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "ConcatenatingAudioSource gapless setVolume seek setAudioSource"`.

**API summary reminder:** `AudioPlayer` is core.
`ConcatenatingAudioSource(children: [...])` gives gapless chained
playback. `setAudioSource(...)` swaps source; `setVolume(double)`
takes 0.0–1.0 (map RG dB → linear via `pow(10, db / 20)`).
`positionStream / durationStream / playerStateStream /
currentIndexStream / sequenceStream` feed the UI.
`LockCachingAudioSource` and `AudioLoadConfiguration` are out of scope.

### `audio_service`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "audio_service"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "BaseAudioHandler AudioServiceConfig MediaItem lockscreen notification android"`.

**API summary reminder:** `AudioService.init(builder: () => handler,
config: ...)` boots the handler. Handler extends `BaseAudioHandler`,
forwards `play / pause / seek / skipToNext / skipToPrevious` to
`PlaybackService`, republishes `playbackState` + `mediaItem` streams.
Manifest needs `FOREGROUND_SERVICE_MEDIA_PLAYBACK` and
`POST_NOTIFICATIONS`; the `<service>` block is merged by the plugin.

### `audiotags`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "audiotags"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "AudioTags.read FLAC MP3 m4a ReplayGain custom tags"`.

**API summary reminder:** `AudioTags.read(path)` returns a `Tag?` with
`title / trackArtist / albumArtist / album / trackNumber / discNumber /
year / genre / duration` + `pictures`. ReplayGain comes from Vorbis
comments / ID3 `TXXX` frames via a generic key/value map — confirm
accessor name during refresh (`Tag.customFields` vs `Tag.extended`
shifted between versions).

### `path_provider`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "path_provider"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "getApplicationDocumentsDirectory getExternalStorageDirectory linux android"`.

**API summary reminder:** Use `getApplicationSupportDirectory()` for
the scan-path preference file (written by slice 2's real Settings row).
Slice 1 hard-codes `~/Music` on Linux and the first readable
`/storage/emulated/0/Music` or app-scoped external dir on Android.
Linux is supported natively.

### `riverpod` + `flutter_riverpod`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "flutter_riverpod"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "ProviderScope StreamProvider AsyncNotifierProvider ref.listen"`.

**API summary reminder:** Slice 1 uses the non-generated API
(`Provider`, `StreamProvider`, `StateNotifierProvider`,
`AsyncNotifierProvider`). No `riverpod_generator` + `build_runner` in
slice 1 — three providers don't justify codegen. Future migration is
additive.

### `melos`

- `mcp__plugin_context7_context7__resolve-library-id libraryName: "melos"`
- `mcp__plugin_context7_context7__query-docs` with
  `topic: "workspace bootstrap scripts pubspec_overrides"`.
- Canonical fallback: `WebFetch https://melos.invertase.dev/~/getting-started`
  and `WebFetch https://melos.invertase.dev/~/configuration/overview`.

**API summary reminder:** `melos bootstrap` wires path deps via
`pubspec_overrides.yaml`. Declare `packages:` globs in `melos.yaml`.
Melos ≥6 integrates with Dart's native `workspace:` — the refresh
confirms whether to set `resolution: workspace` in each `pubspec.yaml`
or rely on Melos overrides.

## 5. Architecture & data flow

```
                    apps/mobile (Flutter app, Riverpod ProviderScope)
                    ┌──────────────────────────────────────────────┐
                    │ AppShell (Scaffold + top-right gear icon)    │
                    │   ├─ TracksScreen   ← tap plays a track      │
                    │   ├─ NowPlayingScreen                        │
                    │   └─ QueueScreen                             │
                    │                                              │
                    │   SettingsScreen (placeholder sections)      │
                    └───────────┬──────────────────────────────────┘
                                │ Riverpod providers
          ┌─────────────────────┼────────────────────────────────┐
          ▼                     ▼                                ▼
   libraryScanProvider    playbackServiceProvider          queueProvider
   (StreamProvider)       (Provider<PlaybackService>)      (StateNotifierProvider)
          │                     │                                │
          ▼                     ▼                                ▼
┌──────────────────┐   ┌──────────────────┐      ┌──────────────────────┐
│ LibraryScanner   │   │ PlaybackService  │◄────►│ QueueService         │
│ (packages/core)  │   │ (packages/       │      │ (packages/playback)  │
│ async* generator │   │   playback)      │      │ three zones + one    │
│ audiotags.read() │   │ just_audio       │      │ ConcatenatingAudio-  │
└────────┬─────────┘   │   + ReplayGain   │      │ Source projection    │
         │             └────────┬─────────┘      └──────────┬───────────┘
         ▼                      ▼                           │
  Track records           AudioPlayer                       │
  (sync Stream)           + AudioHandler    ◄───────────────┘
                                │
                                ▼
                   audio_service (Android MediaSession,
                   Linux MPRIS where the plugin exposes it)
```

**Ownership**

| Box | Package |
|---|---|
| `Track`, `LibraryScanner`, `ScanEvent`, `CancellationToken` | `packages/core` |
| `PlaybackService`, `QueueService`, `QueueZone`, `ReplayGain` | `packages/playback` |
| `AppShell`, `SettingsScreen`, screens, providers, `AudioHandler` adapter | `apps/mobile` |

`packages/core` has zero Flutter imports — pure Dart. Keeps the
scanner unit-testable and lets slice 3's Python indexer contract share
a Dart `Track` shape with the UI without pulling Flutter into tests.

## 6. File layout (new files only)

```
/melos.yaml                                          # workspace globs + scripts
/pubspec.yaml                                        # workspace root (Dart workspace)
/analysis_options.yaml                               # shared lints (flutter_lints)
/apps/mobile/pubspec.yaml                            # Flutter app manifest
/apps/mobile/analysis_options.yaml                   # inherits root lints
/apps/mobile/lib/main.dart                           # entrypoint; AudioService.init + ProviderScope
/apps/mobile/lib/app.dart                            # MaterialApp + routes
/apps/mobile/lib/shell/app_shell.dart                # Scaffold wrapper + gear icon + bottom nav stub
/apps/mobile/lib/shell/settings_screen.dart          # placeholder screen
/apps/mobile/lib/shell/settings_sections.dart        # Library + Playback section placeholder widgets
/apps/mobile/lib/screens/tracks_screen.dart          # flat tracks list, tap to play
/apps/mobile/lib/screens/now_playing_screen.dart     # scrub + transport
/apps/mobile/lib/screens/queue_screen.dart           # three sections (Upcoming/PlayNext/History)
/apps/mobile/lib/audio/audio_handler.dart            # BaseAudioHandler bridging audio_service ↔ PlaybackService
/apps/mobile/lib/providers/library_providers.dart    # libraryScanProvider, tracksProvider
/apps/mobile/lib/providers/playback_providers.dart   # playbackServiceProvider, queueProvider, nowPlayingProvider
/apps/mobile/android/app/src/main/AndroidManifest.xml# generated by flutter create; append MEDIA perms
/apps/mobile/linux/CMakeLists.txt                    # generated by flutter create; no edits in slice 1
/packages/core/pubspec.yaml                          # pure Dart package
/packages/core/lib/core.dart                         # barrel export
/packages/core/lib/src/models/track.dart             # Track record + fromTag factory
/packages/core/lib/src/scanner/library_scanner.dart  # async* walker over a directory
/packages/core/lib/src/scanner/scan_event.dart       # sealed union (Discovered/Skipped/Failed/Done)
/packages/core/lib/src/scanner/cancellation_token.dart # isCancelled / cancel() flag
/packages/core/lib/src/paths/audio_paths.dart        # extension set + default library root per platform
/packages/core/test/scanner_test.dart                # unit tests against a temp dir fixture
/packages/playback/pubspec.yaml                      # depends on core + just_audio + audio_service
/packages/playback/lib/playback.dart                 # barrel export
/packages/playback/lib/src/playback_service.dart     # wraps AudioPlayer; exposes streams
/packages/playback/lib/src/queue_service.dart        # three-zone model + ConcatenatingAudioSource projection
/packages/playback/lib/src/queue_zone.dart           # enum { upcoming, playNext, history } + helpers
/packages/playback/lib/src/replay_gain.dart          # pure dB→linear math + tag → gain resolver
/packages/playback/test/queue_service_test.dart      # insert/move/clear invariants
/packages/playback/test/replay_gain_test.dart        # tag parsing + db math
```

No stub markdown beyond a two-line project root README. Files under
`apps/mobile/{android,linux}/` generated by `flutter create` are left
untouched except for the manifest line in Step 14.

## 7. Interfaces & key types

```dart
// packages/core/lib/src/models/track.dart
class Track {
  final String path;                    // absolute filesystem path
  final int mtimeMs;
  final String? title, artist, albumArtist, album, genre;
  final int? trackNo, discNo, year;
  final Duration? duration;
  final double? replayGainTrackDb;      // parsed from tag, null if absent
  final double? replayGainAlbumDb;
  const Track({...});
  factory Track.fromTag({required String path, required int mtimeMs, required Tag tag});
}
```

Immutable, `==`/`hashCode` by `path` only so re-scan dedup is cheap.
Skip `freezed` to dodge codegen in slice 1; slice 4 can adopt it when
SQLite pulls `build_runner` in anyway.

```dart
// packages/core/lib/src/scanner/library_scanner.dart
class LibraryScanner {
  LibraryScanner({Set<String>? extensions}); // flac, mp3, m4a, ogg, opus, wav
  /// Walks [root] breadth-first, yielding a [ScanEvent] per file.
  /// Emits [ScanDone] exactly once. Honors [token.isCancelled] between
  /// files — a cancel emits [ScanDone(cancelled: true)] without raising.
  Stream<ScanEvent> scan(Directory root, {required CancellationToken token});
}
```

`Stream<ScanEvent>` (not `Stream<Track>`) so callers see failures
without aborting the whole scan; UI turns `ScanDone` into a banner.

```dart
// packages/core/lib/src/scanner/scan_event.dart
sealed class ScanEvent { const ScanEvent(); }
class ScanDiscovered extends ScanEvent { final Track track; ... }
class ScanSkipped extends ScanEvent { final String path; final String reason; ... }
class ScanFailed extends ScanEvent { final String path; final Object error; ... }
class ScanDone extends ScanEvent { final bool cancelled; final int count; ... }
```

```dart
// packages/playback/lib/src/playback_service.dart
class PlaybackService {
  PlaybackService({AudioPlayer? player, bool replayGainEnabled = true});
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<PlayerState> get playerStateStream;
  Stream<int?> get currentIndexStream;
  Stream<Track?> get currentTrackStream;
  Future<void> loadQueue(QueueSnapshot snapshot, {int initialIndex = 0});
  Future<void> play(); Future<void> pause(); Future<void> seek(Duration p);
  Future<void> skipToNext(); Future<void> skipToPrevious();
  Future<void> setReplayGainEnabled(bool on);
  Future<void> dispose();
}
```

One `AudioPlayer`, swapped source on each snapshot. `currentTrackStream`
joins `currentIndexStream` with the latest snapshot — the UI never
cross-references two streams.

```dart
// packages/playback/lib/src/queue_service.dart
class QueueService extends StateNotifier<QueueSnapshot> {
  QueueService() : super(QueueSnapshot.empty());
  void playNext(Track t);           // head of playNext zone
  void addToUpcoming(Track t);      // tail of upcoming zone
  void move(int from, int to);      // indices over the flat projection
  void clearPlayNext();
  void advance();                   // projection head → history; called by PlaybackService
  void loadContext(List<Track> upcoming, {int startIndex = 0});
}
class QueueSnapshot {
  final List<Track> history, playNext, upcoming;  // past / FIFO / contextual
  int get currentIndex;                            // position in flat projection
  List<Track> get flat;                            // history + current + playNext + upcoming
}
```

One immutable snapshot per transition lets `AudioPlayer` diff sources
rather than rebuild (slice 1 rebuilds; slice 5 optimizes once radio
appends continuously). `move` indices over the flat projection so the
UI passes `ReorderableListView` indices directly.

```dart
// apps/mobile/lib/shell/app_shell.dart
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child, required this.title});
  final Widget child; final String title;
  // Scaffold with AppBar(actions: [IconButton(Icons.settings, onPressed:
  //   () => Navigator.push(context, SettingsScreen.route()))]).
  // BottomNavigationBar: 3-item stub (Tracks / Now Playing / Queue).
}

// apps/mobile/lib/shell/settings_screen.dart
class SettingsScreen extends StatelessWidget {
  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());
  // ListView: SectionHeader('Library') + subtitle "Scan path, re-scan,
  // clear cache (slice 2+)", SectionHeader('Playback') + subtitle
  // "ReplayGain, gapless defaults (slice 2+)".
}
```

## 8. Implementation steps

Each step is ordered, ~20–80 LOC, names its files, and states a
one-line pass criterion. Stop at the criterion before the next step.

1. **Bootstrap the workspace.** Write `melos.yaml` (`packages:` globs
   `apps/*`, `packages/*`), root `pubspec.yaml` with `workspace:`
   listing both packages and the app, shared `analysis_options.yaml`
   pulling `flutter_lints`. Activate Melos; `melos bootstrap`.
   **Pass:** `melos list` prints three packages; `melos bootstrap`
   exits 0 twice.

2. **Scaffold the Flutter app.** `cd apps && flutter create
   --platforms=android,linux --org dev.prism mobile`. Append
   `FOREGROUND_SERVICE_MEDIA_PLAYBACK` + `POST_NOTIFICATIONS` to the
   generated manifest. Add `apps/mobile/pubspec.yaml` runtime deps:
   `just_audio`, `audio_service`, `flutter_riverpod`, `path_provider`,
   and path deps on `core` + `playback`.
   **Pass:** `flutter run -d linux` shows the default app;
   `flutter build apk --debug` succeeds.

3. **Define `Track` + extension list.** In `models/track.dart` write
   the immutable `Track` with `==` / `hashCode` by `path`. In
   `paths/audio_paths.dart` expose `const kSupportedExtensions =
   {'.flac','.mp3','.m4a','.ogg','.opus','.wav'}` and a
   `defaultLibraryRoot()` helper (`~/Music` on Linux via
   `Platform.environment['HOME']`, `/storage/emulated/0/Music` on
   Android).
   **Pass:** `dart test packages/core/test/` asserts identity on a
   constructed `Track`.

4. **Implement `LibraryScanner`.** `async*` function: `await for`
   `Directory.list(recursive: true)`, filter by extension, call
   `AudioTags.read(path)`, yield `ScanDiscovered(Track.fromTag(...))`;
   catch per-file errors as `ScanFailed`. Between files, check
   `token.isCancelled` and emit `ScanDone(cancelled: true)` then
   return; else emit `ScanDone(cancelled: false, count: N)` after the
   loop.
   **Pass:** `scanner_test.dart` seeds a temp dir with one valid MP3,
   one unreadable file, one non-audio file; asserts one `ScanDiscovered`,
   one `ScanFailed`, one `ScanSkipped`, one `ScanDone`. A second test
   cancels after the first event and expects `ScanDone(cancelled: true)`.

5. **Wire ReplayGain tag parsing.** In `replay_gain.dart` write two
   pure functions: `double? parseReplayGainDb(String raw)` (handles
   `"+3.12 dB"`, `"-3.1"`, `"3.1dB"`) and `double dbToLinear(double db)
   => pow(10, db / 20).toDouble()`. Extend `Track.fromTag` to read the
   custom-field map for `REPLAYGAIN_TRACK_GAIN` + `_ALBUM_GAIN`.
   **Pass:** `replay_gain_test.dart` checks
   `parseReplayGainDb("+3.12 dB") == 3.12`, `dbToLinear(-6)` within
   `1e-3` of `0.501`, and `Track.fromTag` on a synthesized `Tag`
   populates `replayGainTrackDb`.

6. **Build `QueueService`.** `StateNotifier` with immutable
   `QueueSnapshot`. Implement `playNext`, `addToUpcoming`, `move`,
   `clearPlayNext`, `advance`, `loadContext`. `QueueSnapshot.flat =
   [...history, current, ...playNext, ...upcoming]`.
   **Pass:** `queue_service_test.dart` verifies: (a) `playNext(t)`
   places `t` directly after current; (b) `addToUpcoming(t)` appends
   after PlayNext; (c) `move(from, to)` reorders across zones
   correctly (a PlayNext entry moved down into Upcoming transfers zone
   ownership); (d) `clearPlayNext` empties only that zone;
   (e) `advance` pushes current onto history and promotes from
   PlayNext (preferred) or Upcoming.

7. **Build `PlaybackService`.** Hold an `AudioPlayer`. On each
   `QueueSnapshot` change, rebuild a `ConcatenatingAudioSource` from
   `snapshot.flat` (map each `Track.path` to
   `AudioSource.uri(Uri.file(path))`), call `player.setAudioSource(src,
   initialIndex: snapshot.currentIndex)`. `setVolume` from active
   track's `replayGainTrackDb` when enabled, else 0 dB. Hook
   `currentIndexStream` to `QueueService.advance()` when the index
   moves forward past current.
   **Pass:** manual — 10 tracks play end-to-end with no audible pops.

8. **Bridge `audio_service`.** `audio_handler.dart` extends
   `BaseAudioHandler`. `main.dart` calls `AudioService.init` with
   channel id `dev.prism.audio`, name `Prism playback`, and
   `androidNotificationOngoing: true`. The handler forwards
   `play / pause / seek / skipToNext / skipToPrevious` to
   `PlaybackService` and publishes `MediaItem` from
   `currentTrackStream` + `durationStream`.
   **Pass:** Android lockscreen shows title, artist, and play/pause
   controls while audio is playing.

9. **Build `AppShell` + `SettingsScreen`.** `AppShell` is a `Scaffold`
   with `AppBar(actions: [gear IconButton → SettingsScreen.route()])`;
   body is the passed `child`; three-item `BottomNavigationBar`
   (Tracks / Now Playing / Queue) switches routes. `SettingsScreen`
   is a `ListView` with two `_SectionHeader`s (`Library`, `Playback`)
   and one muted subtitle per section naming the slice that fills it.
   **Pass:** gear icon visible on every tab, pushes the settings route.

10. **Wire providers.** `playback_providers.dart`:
    `Provider<PlaybackService>` (eager, `ref.onDispose`),
    `StateNotifierProvider<QueueService, QueueSnapshot>`, derived
    `StreamProvider<Track?>` for Now Playing.
    `library_providers.dart`: `FutureProvider<List<Track>>` consuming
    `LibraryScanner().scan(...)` to completion; `ScanFailed` events
    fan out to `StateProvider<List<ScanFailed>>` for later UI.
    **Pass:** `TracksScreen` renders a list; cold start completes in
    <3 s for a 500-track library on the Pixel 9 Pro Fold.

11. **Build `TracksScreen`.** `ListView.builder` over the
    `tracksProvider` data. On tap: `ref.read(queueProvider.notifier)
    .loadContext(allTracks, startIndex: i)` then
    `ref.read(playbackServiceProvider).play()`. Each row shows
    `title` / `artist — album` / `duration`.
    **Pass:** tap-to-play works on both Linux and Android.

12. **Build `NowPlayingScreen`.** Watches `currentTrackStream`,
    `positionStream`, `durationStream`, `playerStateStream`. `Slider`
    bound to `seek`, plus play/pause/prev/next `IconButton`s. Plain
    Material 3 — slice 7 replaces visuals.
    **Pass:** scrubber moves during playback; pause toggles state.

13. **Build `QueueScreen`.** Watches `queueProvider`. Three headered
    sections: `History` (read-only), `Up Next` (PlayNext, with
    `Move up` / `Move down` / `Remove` overflow menu per row),
    `Upcoming` (same menu). Top-bar `Clear Up Next` calls
    `clearPlayNext`. Tapping a PlayNext / Upcoming row moves it to
    `currentIndex + 1` then `skipToNext`.
    **Pass:** `playNext` insertion slides visibly above Upcoming;
    Move up / Move down preserves FIFO within PlayNext.

14. **Manifest + permission glue.** Add media foreground service +
    notification permissions to the manifest. On Android 13+, request
    `POST_NOTIFICATIONS` via `audio_service`'s helper before the
    handler attaches.
    **Pass:** fresh Android 14 install shows the permission prompt
    exactly once; lockscreen controls light up on second launch.

15. **Run §11.** **Pass:** every numbered item is green.

## 9. Alternatives considered

**`media_kit` vs `just_audio`.** `media_kit` is libmpv-backed and
handles exotic codecs (including 24-bit FLAC on Linux) out of the box.
`just_audio` uses ExoPlayer on Android and the system stack on Linux,
both of which handle our FLAC library. Chose `just_audio` because
`ConcatenatingAudioSource` is the cleanest gapless API in Dart,
`audio_service` pairs with it natively, and Android MediaSession is
solved for free. Reconsider if Linux 24/96 output distorts or gapless
is audibly not gapless on the Pixel — slice 1 verification catches both.

**`provider` vs `riverpod` vs `bloc`.** `provider` scales poorly across
9 slices — fine-grained `ChangeNotifier`s become manual. `bloc`'s
event/state discipline is overkill for a local-only app with no
network state machines. `riverpod` gives compile-time provider wiring,
scoped test overrides, and stream providers that compose naturally
with `just_audio`. Rejected `provider` for coarseness, `bloc` for
ceremony. Reconsider `bloc` if slice 6 / 8's LLM flow becomes a
multi-step state machine that dwarfs playback — it will not.

**Monorepo from day one vs single-app now, extract later.** Later
extraction is a known tax: import paths churn, tests move, CI forks.
Slice 3's Python indexer is a sibling of the Flutter app and slice 4's
sidecar reader needs to share the `Track` shape. Melos + `apps/mobile`
+ `packages/core` now costs one extra afternoon and saves a messy
refactor in slice 4. Reconsider if Melos overhead disrupts CI — the
fallback is Dart's native `workspace:` support, already the primary
mechanism here.

## 10. Edge cases & known risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Partial scan cancellation leaves the app half-populated. | Scanner emits `ScanDone(cancelled: true)`; `libraryScanProvider` treats canceled scans as stale and keeps the previous complete list, with a snackbar note. |
| 2 | Corrupted or unreadable tag on one file. | `AudioTags.read` throws → emit `ScanFailed(path, error)`, continue the walk. |
| 3 | Android 13+ missing `POST_NOTIFICATIONS`. | Request via `audio_service`'s helper on first launch; if denied, playback still works but lockscreen controls do not. Slice 2 surfaces a Settings row to re-prompt. Slice 1 accepts one first-launch verification miss. |
| 4 | ReplayGain tags absent (common with fresh CD rips). | `replayGainTrackDb == null` → `PlaybackService` applies 0 dB. Slice 4's measured RG backfills via sidecars. |
| 5 | Libraries >10 k tracks block UI during scan. | Scanner streams through `StreamProvider` off the UI isolate. If single-isolate throughput proves insufficient (>2 s to first frame on Pixel), move the walk into `Isolate.run` in step 10 — accept — verify at runtime. |
| 6 | Paths change between runs (device renamed, SD remount). | Slice 1 stores no path state. Default root is re-resolved per launch via `defaultLibraryRoot()`, falling back to `getApplicationDocumentsDirectory()` if neither known location is readable. |
| 7 | Duplicate tracks after re-scan. | `QueueSnapshot.flat` uses `path` as identity; `tracksProvider` dedupes via `Map<String, Track>.putIfAbsent`. |
| 8 | Foldable rotation / inner-outer transition resets playback UI. | `PlaybackService` lives in a root-scoped Riverpod provider, not widget lifecycle. Rotation re-reads streams; it does not dispose the player. |
| 9 | `audio_service` notification channel missing on OEM Android skins. | Explicit `AudioServiceConfig.androidNotificationChannelId/Name` at init; confirm via `adb shell dumpsys notification`. |
| 10 | Linux desktop without MPRIS DBus. | `audio_service` falls back to in-app transport surface. Accept — verify at runtime; Linux is a convenience target in slice 1. |

## 11. Verification

Run in order. Cheap automated checks run under `melos run test`.

1. `melos bootstrap` then `melos run test` passes in both packages
   (`scanner_test.dart`, `queue_service_test.dart`,
   `replay_gain_test.dart`).
2. `flutter run -d linux --flavor dev` starts; `TracksScreen` shows
   `~/Music`. `flutter run -d <pixel_9_pro_fold_serial>` starts; grant
   notification permission when prompted.
4. Play 10 arbitrary tracks end-to-end from `TracksScreen` — no
   crashes; each advances to the next.
5. On an album with a known gapless pair (e.g. Pink Floyd *Dark Side*
   or Daft Punk *Discovery*), scrub to 3 s before the end of the first
   track and confirm the transition is audibly gapless.
6. Lock the Pixel's screen during playback; lockscreen shows title,
   artist, play/pause; pressing `next` advances correctly.
7. ReplayGain sanity: pick a loud track (CD rip, no RG tags, peaks
   near 0 dBFS) and a quiet one (`REPLAYGAIN_TRACK_GAIN ≈ -8 dB`).
   Play back-to-back with ReplayGain enabled; perceived loudness falls
   within ~±2 LUFS — specifically, no sudden jump on track change.
8. Queue: from `TracksScreen`'s long-press menu, select `Play Next`
   on track B while track A is playing. Track B appears at the top of
   `Up Next` in `QueueScreen`, above auto-queued Upcoming tracks.
9. In `QueueScreen`, use `Move up` / `Move down` on a PlayNext row;
   FIFO within the zone updates and the underlying `AudioPlayer` queue
   matches.
10. Settings gear: from each of `TracksScreen`, `NowPlayingScreen`,
    `QueueScreen`, tap the top-right gear; `SettingsScreen` opens and
    shows the two placeholder sections.
11. Cold-start scan perf: on the Pixel with a 5 k-track library, time
    to first non-empty `TracksScreen` list is under 5 s. If exceeded,
    move the scan walk into an isolate per §10 item 5.
12. Kill the app from recents during playback; notification vanishes;
    relaunch starts clean with no lingering ghost session.

## 12. Definition of done

- [ ] `melos.yaml`, root `pubspec.yaml`, and all three package
  `pubspec.yaml` files exist; `melos bootstrap` is idempotent.
- [ ] Path deps resolve: `apps/mobile` → `packages/playback` →
  `packages/core`; no Flutter import leaks into `packages/core`.
- [ ] `flutter analyze` clean on `apps/mobile` and both packages.
- [ ] `melos run test` passes with the four test files listed in §6.
- [ ] `LibraryScanner` honors `CancellationToken`; a canceled scan
  emits exactly one `ScanDone(cancelled: true)`.
- [ ] `QueueService.playNext` places the track directly after current
  in the flat projection, above Upcoming.
- [ ] `QueueService.move` preserves zone semantics across boundaries
  (a PlayNext row moved into Upcoming becomes Upcoming).
- [ ] `PlaybackService` applies `REPLAYGAIN_TRACK_GAIN` when present,
  0 dB otherwise; applied volume visible via the player's `volume`
  getter under test.
- [ ] Gapless transition is audibly seamless on the test pair.
- [ ] Android lockscreen shows art / title / transport controls and
  responds to play / pause / next.
- [ ] The gear icon opens `SettingsScreen` from every top-level
  screen; the screen renders `Library` and `Playback` section
  headers with subtitles naming the slice that fills them in.
- [ ] Cold start to first track list on a 5 k library <5 s on the
  Pixel 9 Pro Fold.
- [ ] Linux build runs, plays audio, does not crash on missing MPRIS.
- [ ] The §4 "Docs to refresh" commands were executed at session
  start and "API summary" notes written before any Dart file was
  touched.
- [ ] No deferred-work sentinels remain — every unfinished item is
  scoped to a later slice and linked here by number.
