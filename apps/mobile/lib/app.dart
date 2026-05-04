import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/ingest_providers.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/now_playing_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/search_screen.dart';
import 'screens/songs_shuffle_tab.dart';
import 'shell/app_shell.dart';
import 'theme/prism_theme.dart';

/// Root widget — [MaterialApp] + the named routes for the top-level
/// surfaces.
///
/// Slice-11 §C — bottom nav becomes Songs / Home / Search / Library.
/// The AI / Create slot is retired entirely; the Songs surface (mood-
/// shuffle deck) is promoted from inside Library to a primary tab. The
/// AI Compose end-of-queue listener that surfaced [EndOfPlaylistSheet]
/// is gone with the AI Compose flow.
///
/// - bottom nav has four tabs (Songs / Home / Search / Library) and
///   `/` is the Home greeting + recents surface;
/// - Now Playing is no longer a bottom tab — the [MiniPlayer] in
///   [AppShell] presents [NowPlayingScreen] as a full-screen overlay
///   route on tap, matching `wireframe/music/screens/mobile-detail.jsx`;
/// - Queue is reachable from inside the Now Playing overlay's bottom
///   utility row, not as a top-level destination.
///
/// The backfill queue still kicks off from inside [LibraryScreen] (its
/// providers chain pulls `backfillKickoffProvider` to start the
/// queue when the user actually sees the library). Doing it from the
/// root would force the metadata repository — and therefore
/// `path_provider` — into every widget test that pumps [PrismApp].
class PrismApp extends ConsumerStatefulWidget {
  const PrismApp({super.key});

  @override
  ConsumerState<PrismApp> createState() => _PrismAppState();
}

class _PrismAppState extends ConsumerState<PrismApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // Boot-time live-tracks ingest (Bug fix — slice-10b §D3 follow-up).
    // Mounting bootIngestProvider here fires IngestController.rescan()
    // exactly once per session as soon as cache.db resolves. Without
    // this, PlaylistEngine throws "library has zero ready tracks" on
    // fresh installs (the live `tracks` table was only populated by the
    // Settings → "Re-scan library" button). The work is microtasked
    // off the UI thread; failures are swallowed inside the provider.
    ref.watch(bootIngestProvider);

    return MaterialApp(
      title: 'Prism',
      navigatorKey: _navKey,
      // Slice 7 — composes ColorScheme.fromSeed (default preset blue),
      // SpaceTokens.mobile, TypographyScale.prism, and the neutral
      // AlbumPalette into one ThemeData. AlbumDetailScreen and
      // NowPlayingScreen wrap their subtree in `Theme(data: ..copyWith)`
      // to override the AlbumPalette per-album; every other route
      // renders against the neutral palette (slice 7 §2 / §5).
      theme: PrismTheme.light(),
      // Slice 10b §A3 — lock the app to light theme. Real PrismTheme.dark()
      // is deferred to slice-12.
      themeMode: ThemeMode.light,
      initialRoute: AppShell.homeRoute,
      routes: {
        AppShell.homeRoute: (_) => const HomeScreen(),
        AppShell.searchRoute: (_) => const SearchScreen(),
        AppShell.libraryRoute: (_) => const LibraryScreen(),
        AppShell.songsRoute: (_) => const SongsShuffleTab(),
        // Now Playing is normally pushed as an overlay by the
        // [MiniPlayer] in [AppShell], but the named route is kept so
        // deep links and external Cast handoffs land on the same
        // screen.
        '/now-playing': (_) => const NowPlayingScreen(),
        '/queue': (_) => const QueueScreen(),
      },
    );
  }
}
