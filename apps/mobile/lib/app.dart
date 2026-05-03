import 'package:flutter/material.dart';

import 'screens/ai_tab.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/new_vibe.dart';
import 'screens/now_playing_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/search_screen.dart';
import 'shell/app_shell.dart';
import 'theme/prism_theme.dart';

/// Root widget — [MaterialApp] + the named routes for the top-level
/// surfaces.
///
/// Restructured to match the wireframe (`wireframe/music/`):
/// - bottom nav has four tabs (Home / Search / Library / Create) and
///   `/` is the Home greeting + featured grid surface (was Library);
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
class PrismApp extends StatelessWidget {
  const PrismApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Prism',
      // Slice 7 — composes ColorScheme.fromSeed (default preset blue),
      // SpaceTokens.mobile, TypographyScale.prism, and the neutral
      // AlbumPalette into one ThemeData. AlbumDetailScreen and
      // NowPlayingScreen wrap their subtree in `Theme(data: ..copyWith)`
      // to override the AlbumPalette per-album; every other route
      // renders against the neutral palette (slice 7 §2 / §5).
      theme: PrismTheme.light(),
      initialRoute: AppShell.homeRoute,
      routes: {
        AppShell.homeRoute: (_) => const HomeScreen(),
        AppShell.searchRoute: (_) => const SearchScreen(),
        AppShell.libraryRoute: (_) => const LibraryScreen(),
        AppShell.aiRoute: (_) => const AiTabScreen(),
        // Now Playing is normally pushed as an overlay by the
        // [MiniPlayer] in [AppShell], but the named route is kept so
        // deep links and external Cast handoffs land on the same
        // screen.
        '/now-playing': (_) => const NowPlayingScreen(),
        '/queue': (_) => const QueueScreen(),
        NewVibeSheet.routeName: (_) => const NewVibeSheet(),
      },
    );
  }
}
