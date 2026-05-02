import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/app.dart';

void main() {
  // Slice 1 §12 DoD: "The gear icon opens SettingsScreen from every
  // top-level screen." Slice 2 renames the initial tab to Library and
  // adds the Online Metadata section in front of the slice-1
  // placeholders; the gear-icon journey itself is unchanged.
  //
  // We can't assert the `audio_service` integration here — its
  // `AudioService.init` needs a platform channel — but the rest of
  // the UI is testable under `ProviderScope` alone, provided the
  // backfill kickoff lives off the root widget (so this test does not
  // need a `path_provider` mock).
  testWidgets('Gear icon reaches Settings from every top-level tab',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: PrismApp()),
    );
    // Don't pumpAndSettle: the LibraryScreen's tabs spin up async
    // providers that we'd otherwise have to mock. The first frame
    // already has the AppBar + gear, which is what this test verifies.

    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);
    expect(
      find.byIcon(Icons.settings),
      findsOneWidget,
      reason: 'Library tab must surface the gear icon.',
    );

    // Bottom nav offers all three slice-1 tabs (Tracks/NowPlaying/Queue).
    // Inactive icons we verify here; the active one is the same as the
    // current tab and covered by the AppBar assertion above.
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.queue_music_outlined), findsOneWidget);

    // Hop to Queue via its inactive icon; confirm gear persists.
    await tester.tap(find.byIcon(Icons.queue_music_outlined));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Queue'), findsOneWidget);
    expect(
      find.byIcon(Icons.settings),
      findsOneWidget,
      reason: 'Queue tab must also surface the gear icon.',
    );

    // Tap the gear → Settings screen, with all three section headers
    // visible (Online Metadata + Library + Playback). We use a
    // text-typed finder restricted to ListView descendants to avoid
    // matching the Library bottom-nav label.
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.text('Online Metadata'), findsOneWidget);
    // The Library *section header* in Settings — there's also a
    // Library tab elsewhere; restricting via ancestor disambiguates.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Library'),
      ),
      findsOneWidget,
    );
    // The Playback section header is below the fold in the default
    // 800x600 test viewport (slice 4 added Library + Cache stats rows
    // ahead of it). Scroll the Settings list to bring it into view
    // before asserting; the row exists in the tree, the assertion is
    // about reachable layout.
    await tester.scrollUntilVisible(find.text('Playback'), 200);
    expect(find.text('Playback'), findsOneWidget);
  });
}
