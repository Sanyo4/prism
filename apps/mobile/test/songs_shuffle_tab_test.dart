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
    // Slice-11 §B2 — Pick a vibe header sits above the multi-select
    // chip row.
    expect(find.text('Pick a vibe'), findsOneWidget);
  });

  testWidgets(
    'slice-11 §B2: tapping chips toggles them in/out of state.chips',
    (tester) async {
      // Watch the notifier directly — we don't want the FilterChip
      // rebuilds to depend on the deck rebuilding (the deck is empty
      // for this test).
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            shuffleDeckProvider.overrideWith(
              (ref) async => const <ShuffleTrack>[],
            ),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              // Capture the container the first time the build runs.
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                theme: PrismTheme.light(),
                home: const Scaffold(body: SongsShuffleTab()),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Empty initial set.
      expect(
        container.read(songsShuffleStateProvider).chips,
        isEmpty,
      );

      // Tap Happy → {happy}.
      await tester.tap(find.text('Happy'));
      await tester.pumpAndSettle();
      expect(
        container.read(songsShuffleStateProvider).chips,
        equals(<MoodChip>{MoodChip.happy}),
      );

      // Tap Energetic → {happy, energetic}.
      await tester.tap(find.text('Energetic'));
      await tester.pumpAndSettle();
      expect(
        container.read(songsShuffleStateProvider).chips,
        equals(<MoodChip>{MoodChip.happy, MoodChip.energetic}),
      );

      // Tap Happy again → {energetic} (toggle off).
      await tester.tap(find.text('Happy'));
      await tester.pumpAndSettle();
      expect(
        container.read(songsShuffleStateProvider).chips,
        equals(<MoodChip>{MoodChip.energetic}),
      );
    },
  );

  testWidgets(
    'slice-11 §B2: chips pass through to shuffleDeckProvider under '
    'True-Shuffle ON (no slice-10b D bypass regression)',
    (tester) async {
      // Capture every chips/trueShuffle pair the deck provider sees.
      final seen = <({Set<MoodChip> chips, bool trueShuffle})>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            shuffleDeckProvider.overrideWith((ref) async {
              final state = ref.watch(songsShuffleStateProvider);
              seen.add((
                chips: Set<MoodChip>.from(state.chips),
                trueShuffle: state.trueShuffle,
              ));
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

      // Toggle True-Shuffle on first.
      await tester.tap(find.byKey(const Key('songs.trueShuffleToggle')));
      await tester.pumpAndSettle();
      // Then select Happy.
      await tester.tap(find.text('Happy'));
      await tester.pumpAndSettle();

      // The most recent provider invocation must show True-Shuffle ON
      // AND chips containing Happy. This is the regression guard for
      // the slice-10b D bypass — under that bug the deck was queried
      // with the chip filter dropped.
      expect(seen, isNotEmpty);
      final last = seen.last;
      expect(last.trueShuffle, isTrue);
      expect(
        last.chips,
        equals(<MoodChip>{MoodChip.happy}),
        reason:
            'True-Shuffle ON must NOT drop the chip filter — slice-11 §B2 '
            'closes the slice-10b D bypass bug.',
      );
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
