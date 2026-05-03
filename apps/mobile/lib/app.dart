import 'package:flutter/material.dart';

import 'screens/ai_tab.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/new_vibe.dart';
import 'screens/now_playing_screen.dart';
import 'screens/queue_screen.dart';
import 'theme/prism_theme.dart';

/// Root widget — [MaterialApp] + the named routes for the top-level
/// surfaces.
///
/// Slice 2 changes:
/// - replaces `tracksRoute` body (was `TracksScreen`) with the
///   5-tab [LibraryScreen]; the route name is preserved so the
///   bottom-nav handler in `AppShell` keeps working.
/// - introduces `homeRoute` for [HomeScreen] (the "Can't decide?"
///   surface); slice 7 will move it ahead of Library in the bottom
///   nav. For slice 2 it's reachable only via deep link / future
///   navigation entries.
///
/// The backfill queue kicks off from inside [LibraryScreen] (its
/// providers chain pulls `backfillKickoffProvider` to start the
/// queue when the user actually sees the library). Doing it from the
/// root would force the metadata repository — and therefore
/// `path_provider` — into every widget test that pumps `PrismApp`.
class PrismApp extends StatelessWidget {
  const PrismApp({super.key});

  // Route names (kept here so consumers don't drift).
  static const homeRoute = '/home';
  static const libraryRoute = '/'; // matches AppShell.tracksRoute by intent

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
      initialRoute: libraryRoute,
      routes: {
        libraryRoute: (_) => const LibraryScreen(),
        homeRoute: (_) => const HomeScreen(),
        '/now-playing': (_) => const NowPlayingScreen(),
        '/queue': (_) => const QueueScreen(),
        // Slice 6 — AI tab landing + the New Vibe sheet.
        '/ai': (_) => const AiTabScreen(),
        NewVibeSheet.routeName: (_) => const NewVibeSheet(),
      },
    );
  }
}
