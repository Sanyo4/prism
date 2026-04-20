import 'package:flutter/material.dart';

import 'settings_screen.dart';

/// Which top-level tab is currently active. Each tab screen passes its
/// own value into [AppShell] so the shell itself stays stateless — the
/// "currently selected tab" bit lives implicitly in the current named
/// route instead of in a [StatefulWidget] bag of local state.
enum AppTab { tracks, nowPlaying, queue }

/// Common scaffold for every top-level screen in the app.
///
/// Responsibilities:
/// - Renders an [AppBar] with a leading title and a trailing gear
///   [IconButton]. Tapping the gear pushes [SettingsScreen] on top of
///   the current tab so popping returns to where the user came from.
/// - Hosts the passed-in [child] as the scaffold body.
/// - Renders the three-item [BottomNavigationBar] whose taps switch
///   between `/` (Tracks), `/now-playing`, and `/queue` via
///   `pushReplacementNamed` — we intentionally replace rather than
///   stack so the navigator never accumulates tab history.
///
/// Slice 7 may swap route-based switching for an [IndexedStack] if
/// list scroll position across tab switches becomes a real grievance.
/// For slice 1 the list is small enough that the rebuild cost doesn't
/// justify the extra stateful widget.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.currentTab,
    required this.child,
    this.actions = const <Widget>[],
  });

  final String title;
  final AppTab currentTab;
  final Widget child;

  /// Extra [AppBar] actions rendered **before** (i.e. left of) the
  /// gear icon. Slice 1 uses this for QueueScreen's `Clear Up Next`
  /// button; future slices may add Search, Shuffle, etc. The gear
  /// always stays rightmost — Material convention for
  /// "more / settings".
  final List<Widget> actions;

  /// Named routes for the three top-level tabs. Declared here so the
  /// shell is the single place mapping [AppTab] → route name and the
  /// consumers ([PrismApp.routes] and the bottom-nav handler) stay in
  /// sync without duplicating string literals.
  static const tracksRoute = '/';
  static const nowPlayingRoute = '/now-playing';
  static const queueRoute = '/queue';

  static String _routeFor(AppTab tab) {
    switch (tab) {
      case AppTab.tracks:
        return tracksRoute;
      case AppTab.nowPlaying:
        return nowPlayingRoute;
      case AppTab.queue:
        return queueRoute;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          ...actions,
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () =>
                Navigator.of(context).push(SettingsScreen.route()),
          ),
        ],
      ),
      body: child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: currentTab.index,
        onTap: (i) {
          final target = AppTab.values[i];
          if (target == currentTab) return;
          Navigator.of(context).pushReplacementNamed(_routeFor(target));
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music_outlined),
            activeIcon: Icon(Icons.library_music),
            label: 'Tracks',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.play_circle_outline),
            activeIcon: Icon(Icons.play_circle),
            label: 'Now Playing',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.queue_music_outlined),
            activeIcon: Icon(Icons.queue_music),
            label: 'Queue',
          ),
        ],
      ),
    );
  }
}
