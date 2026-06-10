import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show PlayerState, ProcessingState;
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/playback_providers.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/screens/now_playing_screen.dart';
import 'package:mobile/theme/palette_providers.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

/// Slice 10b — wireframe `mobile-detail.jsx:243-258` adds a bottom
/// utility row to NowPlayingScreen with [volume / cast / queue]. The
/// queue button is the only path from Now Playing to `/queue` since
/// the route had zero callers before this row was wired.
void main() {
  testWidgets(
    'queue button on NowPlayingScreen pushes /queue route',
    (tester) async {
      // _PlayerView lays out a tall Column; the default 600 px test
      // viewport is too short. Use a phone-sized surface so the bottom
      // utility row paints without overflow assertions.
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const fakeTrack = Track(
        path: '/fake/seed.flac',
        mtimeMs: 0,
        title: 'Seed Track',
        artist: 'Test Artist',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nowPlayingProvider.overrideWith(
              (ref) => Stream<Track?>.value(fakeTrack),
            ),
            positionProvider.overrideWith(
              (ref) => Stream<Duration>.value(Duration.zero),
            ),
            durationProvider.overrideWith(
              (ref) => Stream<Duration?>.value(null),
            ),
            playerStateProvider.overrideWith(
              (ref) => Stream<PlayerState>.value(
                PlayerState(false, ProcessingState.ready),
              ),
            ),
            transportProvider.overrideWith(() => _StubTransportNotifier()),
            radioSessionProvider.overrideWith(() => _StubRadioNotifier(null)),
            paletteRepositoryProvider.overrideWith(
              (ref) => Completer<Never>().future,
            ),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            // Stub `/queue` to a sentinel widget — verifies the route
            // was navigated to without pulling in the real
            // `QueueScreen`'s providers (which would need the metadata
            // repository wired).
            routes: <String, WidgetBuilder>{
              '/': (_) => const NowPlayingScreen(),
              '/queue': (_) => const _QueueSentinel(),
            },
          ),
        ),
      );
      await tester.pump();

      // Sanity: sentinel not yet visible.
      expect(find.byType(_QueueSentinel), findsNothing);

      // Tap the queue button in the bottom utility row.
      final queueButton = find.byKey(const Key('nowPlaying.queueButton'));
      expect(queueButton, findsOneWidget,
          reason: 'Bottom utility row must expose a queue button.');

      // Scroll the button into view if necessary, then tap.
      await tester.ensureVisible(queueButton);
      await tester.pump();
      await tester.tap(queueButton);
      await tester.pumpAndSettle();

      // Sentinel should now be on top.
      expect(find.byType(_QueueSentinel), findsOneWidget);
      expect(find.text('queue-sentinel'), findsOneWidget);
    },
  );
}

class _QueueSentinel extends StatelessWidget {
  const _QueueSentinel();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('queue-sentinel')),
    );
  }
}

class _StubTransport implements CastTransport {
  @override
  String get id => 'local';
  @override
  String get displayName => 'Stub';
  @override
  bool get isLossless => true;
  @override
  Stream<TransportEvent> get events => const Stream.empty();
  @override
  Future<void> setTrack(Track t) async {}
  @override
  Future<void> setNext(Track? t) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _StubTransportNotifier extends TransportNotifier {
  @override
  CastTransport build() => _StubTransport();
}

class _StubRadioNotifier extends RadioSessionNotifier {
  _StubRadioNotifier(this._initial);
  final RadioSession? _initial;

  @override
  RadioSession? build() => _initial;

  @override
  Future<void> startFromTrack(track) async {}

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
