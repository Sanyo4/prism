import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
    test('tag-embedded TRACK_GAIN lands on the fake player as dbToLinear',
        () async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -3.0)]));

      // Slice 1 §11 checklist: "applied volume visible via the player's
      // volume getter under test".
      expect(fake.volume, closeTo(dbToLinear(-3.0), 1e-12));
      expect(fake.volumeCalls, isNotEmpty);
    });

    test('absent tag falls through to 0 dB (volume 1.0)', () async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);

      await service.syncSnapshot(_snapshotOf([_track('a')]));

      expect(fake.volume, equals(1.0));
    });

    test('disabling ReplayGain restores full-scale volume even mid-track',
        () async {
      final fake = _FakePlayer();
      final service = PlaybackService(player: fake);
      addTearDown(service.dispose);
      await service.syncSnapshot(_snapshotOf([_track('a', rgDb: -9.0)]));
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
}
