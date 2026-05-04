import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart';

/// In-memory [AudioPlayerPort] that records every call and exposes
/// the stream controllers test code drives manually. Matches the
/// subset `PlaybackService` actually exercises — no attempt at
/// faithful `just_audio` semantics beyond what the service observes.
class _FakePlayer implements AudioPlayerPort {
  _FakePlayer();

  double _volume = 1.0;
  int? _currentIndex;
  bool _playing = false;
  Duration _position = Duration.zero;
  bool _disposed = false;

  final List<({List<AudioSource> sources, int? initialIndex, Duration? initialPosition})>
      setSourcesCalls = [];
  final List<({Duration position, int? index})> seekCalls = [];
  final List<({int index, AudioSource source})> insertCalls = [];
  final List<int> removeCalls = [];
  final List<({int from, int to})> moveCalls = [];
  int playCalls = 0;
  int pauseCalls = 0;
  final List<double> volumeCalls = [];

  final _indexController = StreamController<int?>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();

  void emitIndex(int? idx) {
    _currentIndex = idx;
    _indexController.add(idx);
  }

  @override
  double get volume => _volume;

  @override
  int? get currentIndex => _currentIndex;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  @override
  Stream<int?> get currentIndexStream => _indexController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _stateController.stream;

  @override
  Future<void> setAudioSources(
    List<AudioSource> audioSources, {
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    setSourcesCalls.add(
      (sources: audioSources, initialIndex: initialIndex, initialPosition: initialPosition),
    );
    _currentIndex = initialIndex;
    if (initialPosition != null) _position = initialPosition;
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource source) async {
    insertCalls.add((index: index, source: source));
    // Mirror just_audio: non-active insert below the active shifts it.
    final cur = _currentIndex;
    if (cur != null && index <= cur) {
      _currentIndex = cur + 1;
    }
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    removeCalls.add(index);
    final cur = _currentIndex;
    if (cur != null && index < cur) {
      _currentIndex = cur - 1;
    }
  }

  @override
  Future<void> moveAudioSource(int from, int to) async {
    moveCalls.add((from: from, to: to));
    final cur = _currentIndex;
    if (cur == null) return;
    // just_audio keeps the active source playing; mirror the index
    // adjustment so tests can assert currentIndex after a move.
    if (from == cur) {
      _currentIndex = to;
    } else if (from < cur && to >= cur) {
      _currentIndex = cur - 1;
    } else if (from > cur && to <= cur) {
      _currentIndex = cur + 1;
    }
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    seekCalls.add((position: position, index: index));
    _position = position;
    if (index != null) _currentIndex = index;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
    _volume = volume;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _indexController.close();
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
  }

  bool get disposed => _disposed;
}

Track _track(String id, {double? rgDb}) => Track(
      path: '/music/$id.flac',
      mtimeMs: 0,
      replayGainTrackDb: rgDb,
    );

QueueSnapshot _snapshotOf(List<Track> tracks, {int currentIndex = 0}) {
  if (tracks.isEmpty) return const QueueSnapshot.empty();
  return QueueSnapshot(
    history: tracks.sublist(0, currentIndex),
    current: tracks[currentIndex],
    upcoming: tracks.sublist(currentIndex + 1),
  );
}

void main() {
  group('PlaybackService.resolveVolume (pure helper)', () {
    test('returns 1.0 when ReplayGain is disabled', () {
      expect(
        PlaybackService.resolveVolume(enabled: false, replayGainTrackDb: -6.0),
        equals(1.0),
      );
    });

    test('returns 1.0 when the tag is absent', () {
      expect(
        PlaybackService.resolveVolume(enabled: true, replayGainTrackDb: null),
        equals(1.0),
      );
    });

    test('applies dbToLinear for a negative gain (common case)', () {
      final expected = dbToLinear(-6.0);
      expect(
        PlaybackService.resolveVolume(enabled: true, replayGainTrackDb: -6.0),
        closeTo(expected, 1e-12),
      );
    });

    test('clamps positive gain (>0 dB) to 1.0 — just_audio cannot boost',
        () {
      // +6 dB would linearly be ~2.0; the player would reject values > 1.
      expect(
        PlaybackService.resolveVolume(enabled: true, replayGainTrackDb: 6.0),
        equals(1.0),
      );
    });
  });

  group('PlaybackService.syncSnapshot: ReplayGain → player.volume', () {
    // These tests use testWidgets + pump so the 40 ms fade-in timer
    // (slice-10b §A6) completes before the volume assertions run.
    testWidgets(
        'tag-embedded TRACK_GAIN lands on the fake player as dbToLinear',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -3.0)]));
      // Advance time past the 40 ms fade-in (8 × 5 ms steps).
      await tester.pump(const Duration(milliseconds: 50));

      // Slice 1 §11 checklist: "applied volume visible via the player's
      // volume getter under test".
      expect(fake.volume, closeTo(dbToLinear(-3.0), 1e-12));
      expect(fake.volumeCalls, isNotEmpty);
    });

    testWidgets('absent tag falls through to 0 dB (volume 1.0)',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a')]));
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.volume, equals(1.0));
    });

    testWidgets(
        'disabling ReplayGain restores full-scale volume even mid-track',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);
      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -9.0)]));
      // Let the fade-in settle so volume reflects the RG-attenuated level.
      await tester.pump(const Duration(milliseconds: 50));
      expect(fake.volume, lessThan(1.0));

      await service.setReplayGainEnabled(false);
      expect(fake.volume, equals(1.0));
    });
  });

  group('PlaybackService.syncSnapshot: rebuild vs reseek branching', () {
    test(
      'identical flat projection with a new currentIndex only seeks — no rebuild',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        final tracks = [_track('a'), _track('b'), _track('c')];
        await service.syncSnapshot(_snapshotOf(tracks, currentIndex: 0));
        // One initial rebuild is expected — baseline.
        expect(fake.setSourcesCalls.length, equals(1));

        // Natural advance: same flat, currentIndex 0 → 1. Equivalent to
        // what QueueService.advance() produces for a plain context.
        await service.syncSnapshot(_snapshotOf(tracks, currentIndex: 1));

        expect(
          fake.setSourcesCalls.length,
          equals(1),
          reason: 'Flat unchanged — must not rebuild the source list.',
        );
        expect(fake.seekCalls, hasLength(1));
        expect(fake.seekCalls.single.index, equals(1));
      },
    );

    test(
      'appending a single track takes the insert fast path — no rebuild',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(_snapshotOf([_track('a'), _track('b')]));
        expect(fake.setSourcesCalls.length, equals(1), reason: 'Baseline.');

        // Same active track, one extra at the tail (addToUpcoming shape).
        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('b'), _track('c')]),
        );

        expect(
          fake.setSourcesCalls.length,
          equals(1),
          reason:
              'Slice-1 cut-out fix: single-element diffs must not rebuild.',
        );
        expect(fake.insertCalls, hasLength(1));
        expect(fake.insertCalls.single.index, equals(2));
      },
    );

    test(
      'playNext shape (insert right after current) takes the insert fast path',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // Active a, upcoming b.
        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('b')], currentIndex: 0),
        );
        // "Play Next x" wedges x between a and b.
        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('x'), _track('b')], currentIndex: 0),
        );

        expect(fake.insertCalls, hasLength(1));
        expect(fake.insertCalls.single.index, equals(1));
        expect(fake.setSourcesCalls.length, equals(1));
      },
    );

    test(
      'removing a non-active track takes the removeAudioSourceAt fast path',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('b'), _track('c')], currentIndex: 0),
        );
        // Drop c from upcoming — active a unchanged.
        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('b')], currentIndex: 0),
        );

        expect(fake.removeCalls, equals([2]));
        expect(fake.setSourcesCalls.length, equals(1));
      },
    );

    test(
      'reordering two non-active tracks takes the moveAudioSource fast path',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('b'), _track('c')], currentIndex: 0),
        );
        // Swap b and c in upcoming — flat: [a, b, c] -> [a, c, b].
        await service.syncSnapshot(
          _snapshotOf([_track('a'), _track('c'), _track('b')], currentIndex: 0),
        );

        expect(fake.moveCalls, hasLength(1));
        expect(fake.setSourcesCalls.length, equals(1));
        // Either (1→2) (b right) or (2→1) (c left) produces the same
        // resulting order; both are acceptable fast-path dispatches.
        final m = fake.moveCalls.single;
        expect(m.from == 1 && m.to == 2 || m.from == 2 && m.to == 1, isTrue,
            reason: 'Expected an adjacent single-element move, got $m.');
      },
    );

    test(
      'active-track change (loadContext-style) falls back to setAudioSources',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(_snapshotOf([_track('a'), _track('b')]));
        // Different tracks entirely — loadContext on a new album.
        await service.syncSnapshot(_snapshotOf([_track('x'), _track('y')]));

        expect(fake.setSourcesCalls.length, equals(2));
        expect(fake.insertCalls, isEmpty);
        expect(fake.removeCalls, isEmpty);
        expect(fake.moveCalls, isEmpty);
      },
    );

    test(
      'multi-element diff (two-element append) falls back to setAudioSources',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(_snapshotOf([_track('a'), _track('b')]));
        // Two new tracks appended at once — not a single-element diff.
        await service.syncSnapshot(
          _snapshotOf(
            [_track('a'), _track('b'), _track('c'), _track('d')],
          ),
        );

        expect(fake.setSourcesCalls.length, equals(2));
        expect(fake.insertCalls, isEmpty);
      },
    );
  });

  group('PlaybackService: natural advance dispatch', () {
    test('player index moving forward by one invokes onAdvance', () async {
      final fake = _FakePlayer();
      var advances = 0;
      final service = PlaybackService(
        player: fake,
        onAdvance: () => advances++,
      );
      addTearDown(service.dispose);

      final tracks = [_track('a'), _track('b')];
      await service.syncSnapshot(_snapshotOf(tracks, currentIndex: 0));

      // just_audio emits during load (currentIndex -> initialIndex). The
      // service suppresses that via _syncing, so the baseline count is 0.
      expect(advances, equals(0));

      fake.emitIndex(1); // natural advance past current
      await Future<void>.delayed(Duration.zero);

      expect(advances, equals(1));
    });

    test('player index moving backward by one invokes onRetreat', () async {
      final fake = _FakePlayer();
      var retreats = 0;
      final service = PlaybackService(
        player: fake,
        onRetreat: () => retreats++,
      );
      addTearDown(service.dispose);

      // Seed with current at index 1 so a backward step is valid.
      await service.syncSnapshot(QueueSnapshot(
        history: [_track('a')],
        current: _track('b'),
      ));

      fake.emitIndex(0);
      await Future<void>.delayed(Duration.zero);

      expect(retreats, equals(1));
    });

    test('dispose releases the player and closes the track stream', () async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      await service.dispose();
      expect(fake.disposed, isTrue);
    });
  });

  group('Slice-4: measured RG (cache) precedence over tag RG', () {
    // Slice-4 §11 item 9 / §12 DoD:
    //   tag = -8 dB, sidecar = -6 dB → plays at dbToLinear(-6) ± 1e-3.
    // testWidgets + pump lets the 40 ms fade-in (slice-10b §A6) settle.
    testWidgets('measured wins over tag when lookup returns a value',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(
        player: fake,
        measuredReplayGainLookup: (track) => -6.0,
      );
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -8.0)]));
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.volume, closeTo(dbToLinear(-6.0), 1e-3));
    });

    testWidgets('tag wins when lookup returns null (no cache row / non-ready)',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(
        player: fake,
        measuredReplayGainLookup: (track) => null,
      );
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -8.0)]));
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.volume, closeTo(dbToLinear(-8.0), 1e-12));
    });

    testWidgets(
        'lookup returning null falls all the way back to 1.0 when no tag',
        (tester) async {
      final fake = _FakePlayer();
      final service = PlaybackService(
        player: fake,
        measuredReplayGainLookup: (track) => null,
      );
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a')]));
      await tester.pump(const Duration(milliseconds: 50));

      expect(fake.volume, equals(1.0));
    });
  });

  // ---------------------------------------------------------------------------
  // Slice-10b §A6: pre-set volume + 40 ms fade-in on track-switch
  // ---------------------------------------------------------------------------
  group('Slice-10b §A6: fade-in on track-switch', () {
    testWidgets(
      'track-switch (rebuild path): volume is 0.0 before source-switch, '
      'ramps monotonically, settles at target ReplayGain level within 50 ms',
      (tester) async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // Drive the first track-switch: null → trackA.
        const rgDb = -6.0;
        final target = PlaybackService.resolveVolume(
          enabled: true,
          replayGainTrackDb: rgDb,
        );

        fake.volumeCalls.clear();
        await service.syncSnapshot(_snapshotOf([_track('a', rgDb: rgDb)]));

        // Invariant 1: the very first volume call after syncSnapshot must
        // be the pre-set silent value.
        expect(
          fake.volumeCalls,
          isNotEmpty,
          reason: 'setVolume must be called during syncSnapshot.',
        );
        expect(
          fake.volumeCalls.first,
          equals(0.0),
          reason: 'Volume must be pre-set to 0.0 before source-switch.',
        );

        // Advance time through the full 40 ms fade-in.
        await tester.pump(const Duration(milliseconds: 50));

        // Invariant 2: calls after the pre-set should be monotonically
        // increasing (the ramp from 0 → target).
        final postPreset = fake.volumeCalls.skip(1).toList();
        expect(postPreset, isNotEmpty,
            reason: 'Fade-in steps must land within 50 ms.');
        for (var i = 1; i < postPreset.length; i++) {
          expect(
            postPreset[i],
            greaterThanOrEqualTo(postPreset[i - 1]),
            reason: 'Volume ramp must be monotonically non-decreasing; '
                'got ${postPreset[i - 1]} → ${postPreset[i]} at step $i.',
          );
        }

        // Invariant 3: final settled volume equals the ReplayGain target.
        expect(
          fake.volume,
          closeTo(target, 1e-9),
          reason: 'Final volume must equal the ReplayGain target.',
        );
      },
    );

    testWidgets(
      'rapid track-switch cancels in-flight fade — no stacked ramps',
      (tester) async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // First track-switch starts a fade.
        await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -6.0)]));

        // Second track-switch before the fade completes.
        // The previous fade must be cancelled; only the new target matters.
        const secondRgDb = -3.0;
        final secondTarget = PlaybackService.resolveVolume(
          enabled: true,
          replayGainTrackDb: secondRgDb,
        );
        fake.volumeCalls.clear();
        await service.syncSnapshot(
          _snapshotOf([_track('b', rgDb: secondRgDb)]),
        );

        // Pre-set 0.0 for the second switch.
        expect(fake.volumeCalls.first, equals(0.0));

        // Let the second fade settle.
        await tester.pump(const Duration(milliseconds: 50));

        // Final volume is the second track's target, not the first's.
        expect(
          fake.volume,
          closeTo(secondTarget, 1e-9),
          reason: 'Final volume must reflect the second (current) track.',
        );
      },
    );

    testWidgets(
      'same-track same-index re-emission does not trigger a fade',
      (tester) async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // Seed with a track and let the initial fade settle.
        await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -6.0)]));
        await tester.pump(const Duration(milliseconds: 50));

        final volumeBeforeResync = fake.volume;
        fake.volumeCalls.clear();

        // Emit the identical snapshot again — flat unchanged, index unchanged.
        await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -6.0)]));

        // No pre-set 0.0 should appear; _applyReplayGain short-circuits on
        // unchanged volume so volumeCalls may be empty.
        expect(
          fake.volumeCalls.contains(0.0),
          isFalse,
          reason: 'A no-op re-emission must not trigger a silent pre-set.',
        );

        // Volume must remain at the previous settled level.
        expect(fake.volume, closeTo(volumeBeforeResync, 1e-9));
      },
    );

    testWidgets(
      'measured ReplayGain (slice-4 hook) is the fade-in target — not tag RG',
      (tester) async {
        final fake = _FakePlayer();
        const measuredDb = -4.0;
        const tagDb = -10.0;
        final service = PlaybackService(
          player: fake,
          measuredReplayGainLookup: (track) => measuredDb,
        );
        addTearDown(service.dispose);

        await service.syncSnapshot(_snapshotOf([_track('a', rgDb: tagDb)]));
        await tester.pump(const Duration(milliseconds: 50));

        final expectedTarget = PlaybackService.resolveVolume(
          enabled: true,
          replayGainTrackDb: measuredDb,
        );
        expect(
          fake.volume,
          closeTo(expectedTarget, 1e-9),
          reason: 'Fade target must use measured RG, not tag RG.',
        );
      },
    );
  });

  // Slice-9 §6 step 6 + §11 — `setTransport` swaps the active
  // [CastTransport] while preserving position + playing flag. The
  // refactor delegates `play / pause / seek / setTrack / setNext`
  // through `_currentTransport`; slice-1 tests above pass
  // byte-identical because their default transport is a
  // `LocalTransport` over the slice-1 fake player and that path is
  // a one-call passthrough.
  //
  // We use a [_TestTransport] fake that records every method call —
  // network and Cast SDK invocations are out of scope here per the
  // brief ("no real-network DLNA / Chromecast invocation in tests").
  group('Slice-9: setTransport swap preserves position + playing flag', () {
    test(
      'swap from a playing local session to a fresh transport plays new transport from preserved position',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // Seed a snapshot so `_snapshot.current` is non-null when
        // setTransport runs. After the seed, drive the fake's
        // playhead + playing flag to simulate "30s into a track,
        // currently playing".
        await service.syncSnapshot(_snapshotOf([_track('a')]));
        fake._playing = true;
        fake._position = const Duration(seconds: 30);

        final next = _TestTransport();
        await service.setTransport(next);

        expect(next.setTrackCalls, hasLength(1),
            reason: 'New transport receives the active track.');
        expect(
          next.seekCalls.single,
          equals(const Duration(seconds: 30)),
          reason: 'Position carries across the swap.',
        );
        expect(next.playCalls, equals(1),
            reason: 'Playing flag carries across the swap.');
        // Slice-9 invariant: setTrack happens BEFORE seek, seek BEFORE play.
        expect(next.callOrder.take(3),
            equals(<String>['setTrack', 'seek', 'play']));
      },
    );

    test(
      'swap from a paused local session does not call play on the new transport',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        await service.syncSnapshot(_snapshotOf([_track('a')]));
        fake._playing = false;
        fake._position = const Duration(seconds: 12);

        final next = _TestTransport();
        await service.setTransport(next);

        expect(next.setTrackCalls, hasLength(1));
        expect(next.seekCalls.single, equals(const Duration(seconds: 12)));
        expect(next.playCalls, equals(0),
            reason: 'Paused transport must not auto-play after a swap.');
      },
    );

    test(
      'swap with no current track skips setTrack / seek / play on the new transport',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        // No syncSnapshot — _snapshot.current stays null.
        final next = _TestTransport();
        await service.setTransport(next);

        expect(next.setTrackCalls, isEmpty);
        expect(next.seekCalls, isEmpty);
        expect(next.playCalls, equals(0));
      },
    );

    test(
      'setTransport is idempotent on identical(currentTransport, next)',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);

        final same = service.currentTransport;
        await service.setTransport(same);

        // Re-asserting `currentTransport` is the same instance is
        // sufficient — the early-return prevents pause / dispose /
        // re-subscribe overhead.
        expect(identical(service.currentTransport, same), isTrue);
      },
    );

    test(
      'play / pause / seek / setTrack / setNext route through currentTransport',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);
        await service.syncSnapshot(_snapshotOf([_track('a')]));

        final transport = _TestTransport();
        await service.setTransport(transport);

        // Snapshot fake call counters AFTER setTransport — the swap
        // intentionally pauses the local player as part of preserving
        // continuity (so the OS audio stack doesn't double-source if
        // a hypothetical mid-swap state existed). We're testing the
        // user-driven path here, not the swap mechanics.
        final pausesAfterSwap = fake.pauseCalls;
        final playsAfterSwap = fake.playCalls;

        await service.play();
        await service.pause();
        await service.seek(const Duration(seconds: 5));
        await service.setTrack(_track('b'));
        await service.setNext(_track('c'));
        await service.setNext(null);

        // setTransport itself fires (setTrack, seek, play) at swap
        // time; we ignore those leading entries and assert the
        // explicit user-driven calls.
        final user = transport.callOrder
            .skipWhile((c) => c != 'pause')
            .toList();
        expect(
          user,
          equals(<String>[
            'pause',
            'seek',
            'setTrack',
            'setNext',
            'setNext',
          ]),
        );
        // The local fake never sees user-driven calls — slice-9's
        // surface routes through the active transport, not the
        // underlying port.
        expect(fake.playCalls, equals(playsAfterSwap),
            reason: 'service.play() must not reach _player when a '
                'remote transport is active.');
        expect(fake.pauseCalls, equals(pausesAfterSwap),
            reason: 'service.pause() must not reach _player when a '
                'remote transport is active.');
      },
    );

    test(
      'remote → remote swap disposes the previous remote transport',
      () async {
        final fake = _FakePlayer();
        final service = PlaybackService(player: fake);
        addTearDown(service.dispose);
        await service.syncSnapshot(_snapshotOf([_track('a')]));

        final first = _TestTransport();
        await service.setTransport(first);
        expect(first.disposeCalls, equals(0));

        final second = _TestTransport();
        await service.setTransport(second);

        // The old remote (non-Local) transport must be disposed so
        // its SOAP poll loop / Cast session is released. Per
        // PlaybackService.setTransport's contract.
        expect(first.disposeCalls, equals(1));
        // The new transport stays live until the next swap or
        // service disposal.
        expect(second.disposeCalls, equals(0));
      },
    );
  });
}

/// In-memory [CastTransport] that records every method call and
/// emits broadcast [TransportEvent]s on demand. Used by the slice-9
/// `setTransport` extension tests above; the brief mandates "no
/// real-network DLNA / Chromecast invocation in tests".
class _TestTransport implements CastTransport {
  _TestTransport();

  @override
  String get id => 'test:${identityHashCode(this)}';

  @override
  String get displayName => 'Test transport';

  @override
  bool get isLossless => true;

  final _eventsController = StreamController<TransportEvent>.broadcast();

  @override
  Stream<TransportEvent> get events => _eventsController.stream;

  final List<Track> setTrackCalls = [];
  final List<Track?> setNextCalls = [];
  final List<Duration> seekCalls = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  /// Invocation order — used by tests to assert the
  /// `setTrack → seek → play` sequence on a swap.
  final List<String> callOrder = [];

  @override
  Future<void> setTrack(Track t) async {
    setTrackCalls.add(t);
    callOrder.add('setTrack');
  }

  @override
  Future<void> setNext(Track? t) async {
    setNextCalls.add(t);
    callOrder.add('setNext');
  }

  @override
  Future<void> play() async {
    playCalls++;
    callOrder.add('play');
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    callOrder.add('pause');
  }

  @override
  Future<void> seek(Duration to) async {
    seekCalls.add(to);
    callOrder.add('seek');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    callOrder.add('stop');
  }

  @override
  Future<void> dispose() async {
    if (_eventsController.isClosed) return;
    disposeCalls++;
    await _eventsController.close();
  }
}
