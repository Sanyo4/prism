import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/providers/songs_shuffle_providers.dart';
import 'package:mobile/screens/songs_shuffle_tab.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart'
    show QueueSnapshot, QueueService, queueProvider;
import 'package:prism_playlist_engine/playlist_engine.dart'
    show RadioSession, SteerChip;
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
    // Vibe header consolidated to single-select push pattern.
    expect(find.text('Pick a vibe'), findsOneWidget);
  });

  testWidgets(
    'tapping a chip pushes a new route (single-select consolidation)',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            shuffleDeckProvider.overrideWith(
              (ref) async => const <ShuffleTrack>[],
            ),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(body: SongsShuffleTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sanity: nothing pushed yet, so canPop() is false.
      var navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isFalse);

      // Tap Chill. The default (single-select) MoodChipRow controller
      // navigates to MoodResultsScreen. We don't pumpAndSettle because
      // MoodResultsScreen reads cache-db-dependent providers we haven't
      // overridden — the screen sits in a loading state forever. A few
      // frames are enough to push the route.
      await tester.tap(find.text('Chill'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isTrue,
          reason:
              'Tapping a chip should push MoodResultsScreen onto the navigator.');
    },
  );

  testWidgets('True Shuffle toggle flips the state',
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

  testWidgets('Infinite ON + queue at threshold triggers startFromTrack',
      (tester) async {
    final startedFrom = <Track>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async => const <ShuffleTrack>[]),
          radioSessionProvider.overrideWith(
            () => _CapturingRadioNotifier((track) => startedFrom.add(track)),
          ),
          queueProvider.overrideWith(() => _StaticQueue()),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Toggle Infinite on.
    await tester.tap(find.byKey(const Key('songs.infiniteToggle')));
    await tester.pumpAndSettle();

    // Drain the static queue below threshold to fire the listener.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SongsShuffleTab)),
    );
    final queue = container.read(queueProvider.notifier) as _StaticQueue;
    queue.shrinkToOne();
    await tester.pumpAndSettle();

    expect(startedFrom, isNotEmpty,
        reason:
            'startFromTrack should fire when queue drains under the threshold');
  });
}

// ---------------------------------------------------------------------------
// Test stubs for the lookahead trigger test (4th case).
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

class _StaticQueue extends QueueService {
  @override
  QueueSnapshot build() {
    // Initial snapshot: a current track + 12 upcoming so the listener
    // sees `remaining > _lookaheadThreshold` and DOES NOT fire.
    final tracks = List<Track>.generate(
      12,
      (i) => Track(path: '/u/$i.flac', mtimeMs: 0, title: 'U$i'),
    );
    return QueueSnapshot(
      current: const Track(path: '/seed.flac', mtimeMs: 0, title: 'Seed'),
      upcoming: List<Track>.unmodifiable(tracks),
    );
  }

  /// Drains the queue down to a single current + nothing in upcoming.
  /// Triggers the Infinite listener because remaining = 1.
  void shrinkToOne() {
    state = const QueueSnapshot(
      current: Track(path: '/seed.flac', mtimeMs: 0, title: 'Seed'),
    );
  }
}
