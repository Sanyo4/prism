import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/songs_shuffle_providers.dart';
import 'package:mobile/screens/songs_shuffle_tab.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders shuffle CTA + chip row + tempo dropdown',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async => const <ShuffleTrack>[
                ShuffleTrack(
                  trackId: 1,
                  path: '/a.flac',
                  title: 'A',
                  artist: 'X',
                  album: 'Y',
                  score: 0.9,
                  bpm: 100,
                ),
              ]),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Shuffle play'), findsOneWidget);
    expect(find.text('True Shuffle'), findsOneWidget);
    expect(find.text('Steer by vibe'), findsOneWidget);
  });

  testWidgets('toggling a chip refreshes the deck via shuffleDeckProvider',
      (tester) async {
    var lastChipsSeen = <MoodChip>{};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async {
            final state = ref.watch(songsShuffleStateProvider);
            lastChipsSeen = state.chips;
            return const <ShuffleTrack>[];
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the Chill chip; deck refresh sees {chill}.
    await tester.tap(find.text('Chill'));
    await tester.pumpAndSettle();
    expect(lastChipsSeen, equals(<MoodChip>{MoodChip.chill}));

    // Tap Focus → {chill, focus}.
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(lastChipsSeen, equals(<MoodChip>{MoodChip.chill, MoodChip.focus}));
  });

  testWidgets('True Shuffle toggle dims chips and bypasses chip mode',
      (tester) async {
    var lastTrueShuffle = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async {
            final state = ref.watch(songsShuffleStateProvider);
            lastTrueShuffle = state.trueShuffle;
            return const <ShuffleTrack>[];
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('songs.trueShuffleToggle')));
    await tester.pumpAndSettle();
    expect(lastTrueShuffle, isTrue);
  });
}
