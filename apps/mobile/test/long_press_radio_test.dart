// Slice-10b regression test (extended in slice-11 §B1): long-pressing
// a deck row in [SongsShuffleTab] opens the radio context sheet AND
// each of its three tiles dispatches the right action:
//
//   1. Play next         → queueProvider.notifier.playNext(track)
//                          + "Added to Play Next" snackbar.
//   2. Add to queue      → queueProvider.notifier.addToUpcoming(track)
//                          + "Added to queue" snackbar.
//   3. Start radio       → radioSessionProvider.notifier.startFromTrack
//                          + "Radio started" snackbar.
//
// The track-only-radio decision (slice-10b) removed album / artist
// long-press surfaces; slice-11 §B1 restored the queue-management
// tiles after slice-10d collapsed the sheet to radio-only. This test
// pins the deck-row entry point + every tile so a future refactor
// can't silently kill the only remaining shuffle-tab long-press
// affordance.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/providers/songs_shuffle_providers.dart';
import 'package:mobile/screens/songs_shuffle_tab.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart'
    show QueueService, QueueSnapshot, queueProvider;
import 'package:prism_playlist_engine/playlist_engine.dart'
    show RadioSession, SteerChip;
import 'package:shared_preferences/shared_preferences.dart';

const _seedTrack = Track(
  path: '/seed.flac',
  mtimeMs: 0,
  title: 'Seed Song',
  artist: 'Seed Artist',
  album: 'Seed Album',
);

const _deckTrack = ShuffleTrack(
  trackId: 42,
  path: '/seed.flac',
  title: 'Seed Song',
  artist: 'Seed Artist',
  album: 'Seed Album',
  score: 0.9,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'long-press on a deck row routes through RadioContextSheet → '
    'startFromTrack',
    (tester) async {
      final startedFrom = <Track>[];
      final recordingQueue = _RecordingQueue();

      await tester.pumpWidget(
        _harness(
          startedFrom: startedFrom,
          queue: recordingQueue,
        ),
      );
      await tester.pumpAndSettle();

      // Long-press the deck row — title text is the most stable
      // hit-target for the ListTile.
      await tester.longPress(find.text('Seed Song'));
      // First pump shows the modal bottom sheet; settle so the
      // "Start radio from this track" ListTile is hittable.
      await tester.pumpAndSettle();

      // The sheet renders all three action tiles.
      expect(find.text('Play next'), findsOneWidget,
          reason: 'Play next tile should render.');
      expect(find.text('Add to queue'), findsOneWidget,
          reason: 'Add to queue tile should render.');
      expect(
        find.text('Start radio from this track'),
        findsOneWidget,
        reason:
            'Long-press should open RadioContextSheet with a Start radio tile.',
      );

      // Tap the radio tile — should dispatch startFromTrack.
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
      expect(
        find.text('Radio started'),
        findsOneWidget,
        reason: 'Radio tile should surface the "Radio started" snackbar.',
      );
    },
  );

  testWidgets(
    'tapping Play next dispatches queueProvider.playNext + snackbar',
    (tester) async {
      final startedFrom = <Track>[];
      final recordingQueue = _RecordingQueue();

      await tester.pumpWidget(
        _harness(
          startedFrom: startedFrom,
          queue: recordingQueue,
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Seed Song'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();

      expect(
        recordingQueue.playNextCalls,
        hasLength(1),
        reason: 'Play next tile should call playNext exactly once.',
      );
      expect(
        recordingQueue.playNextCalls.single.path,
        '/seed.flac',
        reason:
            'playNext should receive the Track resolved from the long-pressed row.',
      );
      expect(
        recordingQueue.addToUpcomingCalls,
        isEmpty,
        reason: 'Play next must not also append to upcoming.',
      );
      expect(
        startedFrom,
        isEmpty,
        reason: 'Play next must not start a radio session.',
      );
      expect(
        find.text('Added to Play Next'),
        findsOneWidget,
        reason: 'Play next tile should surface the "Added to Play Next" snackbar.',
      );
    },
  );

  testWidgets(
    'tapping Add to queue dispatches queueProvider.addToUpcoming + snackbar',
    (tester) async {
      final startedFrom = <Track>[];
      final recordingQueue = _RecordingQueue();

      await tester.pumpWidget(
        _harness(
          startedFrom: startedFrom,
          queue: recordingQueue,
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Seed Song'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      expect(
        recordingQueue.addToUpcomingCalls,
        hasLength(1),
        reason: 'Add to queue tile should call addToUpcoming exactly once.',
      );
      expect(
        recordingQueue.addToUpcomingCalls.single.path,
        '/seed.flac',
        reason:
            'addToUpcoming should receive the Track resolved from the long-pressed row.',
      );
      expect(
        recordingQueue.playNextCalls,
        isEmpty,
        reason: 'Add to queue must not also insert at PlayNext head.',
      );
      expect(
        startedFrom,
        isEmpty,
        reason: 'Add to queue must not start a radio session.',
      );
      expect(
        find.text('Added to queue'),
        findsOneWidget,
        reason: 'Add to queue tile should surface the "Added to queue" snackbar.',
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Widget _harness({
  required List<Track> startedFrom,
  required _RecordingQueue queue,
}) {
  return ProviderScope(
    overrides: [
      shuffleDeckProvider
          .overrideWith((ref) async => const <ShuffleTrack>[_deckTrack]),
      radioSessionProvider.overrideWith(
        () => _CapturingRadioNotifier((track) => startedFrom.add(track)),
      ),
      queueProvider.overrideWith(() => queue),
      // The notifier resolves the live Track via
      // `trackByIdLookupProvider` — stub it to return the seed
      // track keyed by its trackId so the sheet's tile dispatch
      // doesn't bail on a null lookup.
      trackByIdLookupProvider.overrideWith(
        (ref) => (id) => id == 42 ? _seedTrack : null,
      ),
    ],
    child: MaterialApp(
      theme: PrismTheme.light(),
      home: const Scaffold(body: SongsShuffleTab()),
    ),
  );
}

// ---------------------------------------------------------------------------
// Test stubs — mirror the songs_shuffle_tab_test pattern.
// ---------------------------------------------------------------------------

/// QueueService stub that records every `playNext` / `addToUpcoming`
/// call so the slice-11 §B1 tile assertions can read them back. The
/// `loadContext` path is unused by the sheet so we don't bother
/// recording it here.
class _RecordingQueue extends QueueService {
  final List<Track> playNextCalls = <Track>[];
  final List<Track> addToUpcomingCalls = <Track>[];

  @override
  QueueSnapshot build() => const QueueSnapshot.empty();

  @override
  void playNext(Track track) {
    playNextCalls.add(track);
    super.playNext(track);
  }

  @override
  void addToUpcoming(Track track) {
    addToUpcomingCalls.add(track);
    super.addToUpcoming(track);
  }
}

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
