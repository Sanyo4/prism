import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app.dart';
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/llm_providers.dart';
import 'package:mobile/shell/app_shell.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';

/// Slice 10 §2.6 rewrite — exercises the gear icon from every entry in
/// [AppTab.values] using `find.byTooltip('Settings')`. Source of truth
/// is the enum, so adding a new tab updates one place (the enum) and
/// the test follows.
void main() {
  testWidgets('Settings reachable via the gear icon from every top-level tab',
      (tester) async {
    // Slice 6's `SettingsLlmSection` watches `ollamaHealthProvider`,
    // which polls `localhost:11434` over HTTP. In a widget test
    // there's no network and the framework refuses real HTTP, so we
    // override the stream with a synthetic "down" snapshot — we're
    // testing the gear-icon journey, not Ollama liveness.
    //
    // Slice 9 — the SettingsScreen now renders `CastSection` which
    // subscribes to `castDiscoveryProvider`. Override with an empty
    // broadcast stream so the section renders without spinning a timer.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.down,
              detail: 'overridden in widget test',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
        ],
        child: const PrismApp(),
      ),
    );
    // Don't pumpAndSettle: tab screens spin up async providers that
    // we'd otherwise have to mock. The first frame already has the
    // _GlassNavBar settings affordance, which is what this test
    // verifies.
    await tester.pump();

    for (final tab in AppTab.values) {
      // Navigate to the tab by replacing the current route. Access the
      // navigator through the element tree — PrismApp's navigatorKey is
      // private, so we look up the Navigator widget directly.
      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pushReplacementNamed(_routeFor(tab));
      // Pump one frame to begin the route transition.
      await tester.pump();
      // MaterialPageRoute transition duration is 300 ms on desktop.
      // Pump small increments to advance the animation clock so the
      // AnimationController reaches AnimationStatus.completed and the
      // Navigator removes the IgnorePointer from the incoming route.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The gear icon's tooltip is the source of truth (slice 10 §2.6).
      // The _GlassNavBar always renders an IconButton(tooltip:'Settings')
      // so there is at least one Settings affordance on every tab
      // regardless of showAppBar.
      expect(
        find.byTooltip('Settings'),
        findsAtLeastNWidgets(1),
        reason: 'Tab "${tab.name}" must surface a Settings affordance',
      );

      // Tap the Settings IconButton by targeting its icon directly.
      // The IconButton inside _GlassNavBar uses Icons.settings_outlined;
      // the AppBar gear (on tabs where showAppBar:true) uses Icons.settings.
      // Both are wrapped by Tooltip('Settings'). We prefer to tap via the
      // icon so the InkWell gesture is registered (not the Tooltip long-
      // press GestureDetector), and we use `.first` to be deterministic.
      final gearIcon = find.byIcon(Icons.settings_outlined);
      final appBarGear = find.byIcon(Icons.settings);
      final iconFinder = gearIcon.evaluate().isNotEmpty ? gearIcon : appBarGear;
      await tester.tap(iconFinder.first);
      // Let the push animation run past the threshold where SettingsScreen
      // renders its AppBar title text. Avoid pumpAndSettle because the
      // SettingsScreen's async providers (ollamaHealth, castDiscovery)
      // may never fully settle.
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // SettingsScreen should be on top with its AppBar title.
      expect(
        find.widgetWithText(AppBar, 'Settings'),
        findsOneWidget,
        reason:
            'Tap should navigate to SettingsScreen for tab "${tab.name}"',
      );

      // Pop back to the tab so the next iteration starts clean.
      nav.pop();
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }
  });
}

/// Maps each [AppTab] to its named route in [AppShell].
String _routeFor(AppTab tab) {
  switch (tab) {
    case AppTab.home:
      return AppShell.homeRoute;
    case AppTab.search:
      return AppShell.searchRoute;
    case AppTab.library:
      return AppShell.libraryRoute;
    case AppTab.ai:
      return AppShell.aiRoute;
  }
}
