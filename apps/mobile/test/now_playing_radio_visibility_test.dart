import 'dart:async';
import 'dart:typed_data';

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
import 'package:mobile/widgets/radio_badge.dart';
import 'package:mobile/widgets/steer_chip_bar.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

void main() {
  testWidgets('no radio session: neither RadioBadge nor SteerChipBar render',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // nowPlayingProvider: null track → _IdleView (no PlayerView).
          nowPlayingProvider.overrideWith(
            (ref) => Stream<Track?>.value(null),
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
          // transportProvider throws by default — provide a stub.
          transportProvider.overrideWith(() => _StubTransportNotifier()),
          // radioSessionProvider: null → no radio session.
          radioSessionProvider.overrideWith(
            () => _StubRadioNotifier(null),
          ),
          // paletteRepositoryProvider: never resolves to avoid sqflite.
          paletteRepositoryProvider.overrideWith(
            (ref) => Completer<Never>().future,
          ),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const NowPlayingScreen(),
        ),
      ),
    );
    await tester.pump();

    // Both widgets should be absent from the tree (not just shrunk).
    expect(find.byType(RadioBadge), findsNothing);
    expect(find.byType(SteerChipBar), findsNothing);
  });

  testWidgets('active session: both render', (tester) async {
    // The _PlayerView Column needs more vertical room than the default
    // 600 px test viewport. Use a phone-sized surface so everything lays
    // out without overflow assertions.
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fakeSession = RadioSession(
      seed: const TrackSeed(trackId: 1, title: 'Seed'),
      seedEmbedding: Float32List(1280)..[0] = 1.0,
    );
    // Provide a non-null track so the screen shows _PlayerView (not _IdleView).
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
          radioSessionProvider.overrideWith(
            () => _StubRadioNotifier(fakeSession),
          ),
          paletteRepositoryProvider.overrideWith(
            (ref) => Completer<Never>().future,
          ),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const NowPlayingScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RadioBadge), findsOneWidget);
    expect(find.text('RADIO'), findsOneWidget);
    expect(find.byType(SteerChipBar), findsOneWidget);
  });
}

/// Minimal stub transport that satisfies CastTransport without any
/// real player wiring. NowPlayingScreen only reads `transport.id`
/// (to decide whether to show the cast-connected icon).
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
  Future<void> toggleChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    state = current.withChipToggled(chip);
  }

  @override
  Future<void> clearChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    state = current.withChipCleared(chip);
  }

  @override
  Future<void> stop() async {
    state = null;
  }
}
