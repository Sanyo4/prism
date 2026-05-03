import 'package:flutter/material.dart';
import 'package:prism_ui/ui.dart';

import '../widgets/mini_player.dart';
import 'settings_screen.dart';

/// Which top-level tab is currently active. Each tab screen passes its
/// own value into [AppShell] so the shell itself stays stateless — the
/// "currently selected tab" bit lives implicitly in the current named
/// route instead of in a [StatefulWidget] bag of local state.
///
/// Restructured to match the wireframe (`wireframe/music/screens/`)
/// — Home / Search / Library / Create. The previous MVP order
/// (tracks / nowPlaying / queue / ai) reflected the older surface
/// design; the wireframe uses a glass tab pill bar with the four
/// browse-oriented destinations and surfaces "now playing" through a
/// MiniPlayer + full-screen overlay rather than a bottom tab.
///
/// Order is significant — bottom-nav indexes by the enum's index.
enum AppTab { home, search, library, ai }

/// Common scaffold for every top-level screen in the app.
///
/// Responsibilities:
/// - Wraps the route subtree in [AuroraBackground] so the dark navy
///   page surrounds shown in the wireframe staging are replaced with
///   the warm cream + pastel aurora that the mobile app actually
///   renders inside the phone frame.
/// - Renders an optional [AppBar]. The main tab routes (home, search,
///   library, ai) draw their own custom typography headers in the
///   body and pass [showAppBar] = false so the shell stays out of the
///   way; settings / album-detail / radio routes still get a stock
///   Material AppBar via [showAppBar] = true.
/// - Hosts the passed-in [child] as the scaffold body.
/// - Renders the [MiniPlayer] as a floating glass pill above the
///   [BottomNavigationBar]. Tapping the mini player presents the
///   `NowPlayingScreen` as a full-screen overlay (route push), not a
///   bottom-nav tab — matching the wireframe's interaction model.
/// - Renders the four-item [BottomNavigationBar] whose taps switch
///   between Home / Search / Library / Create.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.currentTab,
    required this.child,
    this.actions = const <Widget>[],
    this.useAurora,
    this.auroraAccentOverride,
    this.showAppBar = true,
    this.showMiniPlayer = true,
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

  /// Slice 7 §13 — when set, picks the [AuroraBackground] variant.
  /// Defaults to a sensible per-tab variant when null.
  final AuroraVariant? useAurora;

  /// Optional accent override piped into [AuroraBackground]. Only
  /// honored by `album` and `player` variants; ignored otherwise.
  final Color? auroraAccentOverride;

  /// When false, the scaffold renders without an [AppBar]. Main
  /// tab routes use this so their custom typography header (e.g.
  /// the wireframe's "Soft landing, welcome back.") is the only
  /// thing at the top of the body.
  final bool showAppBar;

  /// When true (default), the [MiniPlayer] floats above the
  /// bottom nav. Routes that present *as* the now-playing surface
  /// (the full-screen overlay) pass false to avoid stacking two
  /// players on top of each other.
  final bool showMiniPlayer;

  /// Named routes for the four top-level tabs. Declared here so the
  /// shell is the single place mapping [AppTab] → route name and the
  /// consumers ([PrismApp.routes] and the bottom-nav handler) stay in
  /// sync without duplicating string literals.
  static const homeRoute = '/';
  static const searchRoute = '/search';
  static const libraryRoute = '/library';
  // Slice 6 — AI tab landing route; rebranded to "Create" in the
  // wireframe, route name kept stable for back-compat with deep
  // links and existing settings/widget tests that reference it.
  static const aiRoute = '/ai';

  static String _routeFor(AppTab tab) {
    switch (tab) {
      case AppTab.home:
        return homeRoute;
      case AppTab.search:
        return searchRoute;
      case AppTab.library:
        return libraryRoute;
      case AppTab.ai:
        return aiRoute;
    }
  }

  AuroraVariant _defaultVariantFor(AppTab tab) {
    switch (tab) {
      case AppTab.home:
        return AuroraVariant.home;
      case AppTab.search:
        return AuroraVariant.library;
      case AppTab.library:
        return AuroraVariant.library;
      case AppTab.ai:
        return AuroraVariant.ai;
    }
  }

  @override
  Widget build(BuildContext context) {
    final variant = useAurora ?? _defaultVariantFor(currentTab);
    return AuroraBackground(
      variant: variant,
      accentOverride: auroraAccentOverride,
      child: Scaffold(
        // Aurora paints the backdrop; Scaffold default would obscure
        // it. `extendBody*` lets the aurora bleed through both the
        // AppBar and BottomNavigationBar regions for the wireframe's
        // edge-to-edge glass look.
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: showAppBar
            ? AppBar(
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
              )
            : null,
        body: child,
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showMiniPlayer) const MiniPlayer(),
                _GlassNavBar(
                  currentTab: currentTab,
                  onTap: (target) {
                    if (target == currentTab) return;
                    Navigator.of(context)
                        .pushReplacementNamed(_routeFor(target));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass tab pill — matches `wireframe/music/screens/mobile-shell.jsx`'s
/// `BottomNav`. Four equal-width pills inside a [Glass] (heavy
/// intensity) with a brightened background on the active item.
class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.currentTab,
    required this.onTap,
  });

  final AppTab currentTab;
  final ValueChanged<AppTab> onTap;

  static const _items = <_NavSpec>[
    _NavSpec(
      tab: AppTab.home,
      iconOutlined: Icons.home_outlined,
      iconActive: Icons.home,
      label: 'Home',
    ),
    _NavSpec(
      tab: AppTab.search,
      iconOutlined: Icons.search,
      iconActive: Icons.search,
      label: 'Search',
    ),
    _NavSpec(
      tab: AppTab.library,
      iconOutlined: Icons.library_music_outlined,
      iconActive: Icons.library_music,
      label: 'Library',
    ),
    _NavSpec(
      tab: AppTab.ai,
      iconOutlined: Icons.auto_awesome_outlined,
      iconActive: Icons.auto_awesome,
      label: 'Create',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.extension<AlbumPalette>();
    final accent = palette?.isNeutral == false
        ? palette!.dominant
        : theme.colorScheme.primary;
    return Glass(
      intensity: GlassIntensity.heavy,
      radius: 28,
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          for (final it in _items)
            Expanded(
              child: _GlassNavTile(
                spec: it,
                active: it.tab == currentTab,
                accent: accent,
                onTap: () => onTap(it.tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavSpec {
  const _NavSpec({
    required this.tab,
    required this.iconOutlined,
    required this.iconActive,
    required this.label,
  });
  final AppTab tab;
  final IconData iconOutlined;
  final IconData iconActive;
  final String label;
}

class _GlassNavTile extends StatelessWidget {
  const _GlassNavTile({
    required this.spec,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  final _NavSpec spec;
  final bool active;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.white.withValues(alpha: 0.92),
                    Colors.white.withValues(alpha: 0.55),
                  ],
                )
              : null,
          boxShadow: active
              ? <BoxShadow>[
                  BoxShadow(
                    color: accent.withValues(alpha: 0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? spec.iconActive : spec.iconOutlined,
              size: 20,
              color: active
                  ? accent
                  : theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 3),
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: active
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
