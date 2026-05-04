import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_playback/playback.dart' show QueueSnapshot, queueProvider;

import 'providers/ai_compose_playback_providers.dart';
import 'screens/ai_tab.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/new_vibe.dart';
import 'screens/now_playing_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/search_screen.dart';
import 'shell/app_shell.dart';
import 'theme/prism_theme.dart';
import 'widgets/end_of_playlist_sheet.dart';

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
class PrismApp extends ConsumerStatefulWidget {
  const PrismApp({super.key});

  @override
  ConsumerState<PrismApp> createState() => _PrismAppState();
}

class _PrismAppState extends ConsumerState<PrismApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // End-of-queue observer (slice 10 §2.3): when the queue drains AND
    // an AI Compose playback is registered AND the last-known current
    // was in that playlist, surface EndOfPlaylistSheet and clear the
    // registered playback state. Cancel ('Done' on the sheet) keeps
    // the just-finished playlist as the active queue.
    ref.listen<QueueSnapshot>(queueProvider, (prev, next) {
      if (prev == null) return;
      final hadCurrent = prev.current != null;
      final drained = next.current == null &&
          next.upcoming.isEmpty &&
          next.playNext.isEmpty;
      if (!(hadCurrent && drained)) return;
      final aiPlayback = ref.read(aiComposePlaybackProvider);
      if (aiPlayback == null) return;
      final lastTrack = prev.current!;
      final partOfAiPlaylist =
          aiPlayback.tracks.any((t) => t.path == lastTrack.path);
      if (!partOfAiPlaylist) return;
      // Schedule the sheet on the next frame so we don't trigger
      // navigator changes inside a build.
      //
      // Clear the registered playback BEFORE showing the sheet so a
      // swipe-dismiss (which doesn't run either button handler) still
      // leaves no stale state — preventing a re-trigger on the next
      // drain. The button handlers still call clear() idempotently as
      // defense-in-depth; redundant calls are harmless.
      ref.read(aiComposePlaybackProvider.notifier).clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navKey.currentContext;
        if (ctx == null) return;
        // ignore: discarded_futures
        EndOfPlaylistSheet.show(ctx, aiPlayback);
      });
    });

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
