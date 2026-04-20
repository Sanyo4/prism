import 'package:flutter/material.dart';

import 'screens/now_playing_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/tracks_screen.dart';
import 'shell/app_shell.dart';

/// Root widget — [MaterialApp] + the named routes for the three
/// top-level tabs.
///
/// The gear-triggered [SettingsScreen] is pushed on top of whichever
/// tab is current (see [AppShell]); it is intentionally *not* a named
/// route, because we want a plain pop to return to the tab the user
/// came from instead of resetting to Tracks.
class PrismApp extends StatelessWidget {
  const PrismApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Prism',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      initialRoute: AppShell.tracksRoute,
      routes: {
        AppShell.tracksRoute: (_) => const TracksScreen(),
        AppShell.nowPlayingRoute: (_) => const NowPlayingScreen(),
        AppShell.queueRoute: (_) => const QueueScreen(),
      },
    );
  }
}
