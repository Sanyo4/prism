// Slice-10b regression test: long-pressing a deck row in
// [SongsShuffleTab] opens the radio context sheet AND its
// "Start radio from this track" tile dispatches `startFromTrack`
// on [radioSessionProvider]'s notifier.
//
// The track-only-radio decision (slice-10b) removed album / artist
// long-press surfaces; this test pins the deck-row entry point so a
// future refactor can't silently kill the only remaining shuffle-tab
// long-press affordance.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/providers/songs_shuffle_providers.dart';
import 'package:mobile/screens/songs_shuffle_tab.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart'
    show RadioSession, SteerChip;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'long-press on a deck row routes through RadioContextSheet → '
    'startFromTrack',
    (tester) async {
      final startedFrom = <Track>[];
      const deckTrack = ShuffleTrack(
        trackId: 42,
        path: '/seed.flac',
        title: 'Seed Song',
        artist: 'Seed Artist',
        album: 'Seed Album',
        score: 0.9,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            shuffleDeckProvider
                .overrideWith((ref) async => const <ShuffleTrack>[deckTrack]),
            radioSessionProvider.overrideWith(
              () => _CapturingRadioNotifier((track) => startedFrom.add(track)),
            ),
            // The notifier resolves the live Track via
            // `trackByIdLookupProvider` — stub it to return the seed
            // track keyed by its trackId so the sheet's tile dispatch
            // doesn't bail on a null lookup.
            trackByIdLookupProvider.overrideWith(
              (ref) => (id) => id == 42
                  ? const Track(
                      path: '/seed.flac',
                      mtimeMs: 0,
                      title: 'Seed Song',
                      artist: 'Seed Artist',
                      album: 'Seed Album',
                    )
                  : null,
            ),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(body: SongsShuffleTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Long-press the deck row — title text is the most stable
      // hit-target for the ListTile.
      await tester.longPress(find.text('Seed Song'));
      // First pump shows the modal bottom sheet; settle so the
      // "Start radio from this track" ListTile is hittable.
      await tester.pumpAndSettle();

      // The sheet renders a ListTile with the action label.
      expect(
        find.text('Start radio from this track'),
        findsOneWidget,
        reason:
            'Long-press should open RadioContextSheet with TrackSeed.',
      );

      // Tap the action tile — should dispatch startFromTrack.
      await tester.tap(find.text('Start radio from this track'));
      await tester.pumpAndSettle();

      expect(
        startedFrom,
        hasLength(1),
        reason:
            'Tapping the radio tile should call startFromTrack exactly once.',
      );
      expect(
        startedFrom.first.path,
        '/seed.flac',
        reason: 'The dispatched Track should match the long-pressed deck row.',
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Test stubs — mirror the songs_shuffle_tab_test pattern.
// ---------------------------------------------------------------------------

class _CapturingRadioNotifier extends RadioSessionNotifier {
  _CapturingRadioNotifier(this._onStart);
  final void Function(Track) _onStart;

  @override
  RadioSession? build() => null;

  @override
  Future<void> startFromTrack(Track track) async {
    _onStart(track);
    // Don't actually boot a session; the test only needs to observe
    // the call.
  }

  @override
  Future<void> startFromAlbum({
    required String albumKey,
    required String title,
  }) async {}

  @override
  Future<void> startFromArtist({
    required String artist,
    required String label,
  }) async {}

  @override
  Future<void> toggleChip(SteerChip chip) async {}

  @override
  Future<void> clearChip(SteerChip chip) async {}

  @override
  Future<void> stop() async {}
}
