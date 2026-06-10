import 'dart:async';

import 'package:prism_core/core.dart';

import 'cast_transport.dart';

/// Narrow handle the [LocalTransport] needs from a local player.
///
/// Slice-9 §3's hard constraint forbids `prism_cast` from importing
/// sibling packages beyond `prism_core`. The slice-1
/// `AudioPlayerPort` therefore can't appear here as a type
/// directly — Track B's `PlaybackService` refactor implements this
/// interface as a thin adapter over the existing
/// `AudioPlayerPort`. The signatures mirror exactly the subset
/// `LocalTransport` exercises so the adapter is mechanical.
///
/// TODO(slice-9-integration): Track B confirms the adapter shape;
/// the field names match `AudioPlayerPort`'s slice-1 surface.
abstract class LocalAudioHandle {
  /// `true` when the player is in the "requested to play" state.
  bool get playing;

  /// Current playhead within the active source.
  Duration get position;

  /// Emits playhead updates at the backend's ticking rate.
  Stream<Duration> get positionStream;

  /// Emits the duration of the active source when known.
  Stream<Duration?> get durationStream;

  /// Loads [t] as the only entry on the local player. The adapter
  /// builds an `AudioSource.uri(Uri.file(t.path))` and calls
  /// `setAudioSources([source])`.
  Future<void> loadTrack(Track t);

  /// Inserts [t] right after the current source so natural advance
  /// (or `skipToNext`) plays it. `null` clears the queued next.
  Future<void> setNext(Track? t);

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> stop();
  Future<void> dispose();
}

/// Local-speaker transport. Wraps slice-1's player surface (via
/// the [LocalAudioHandle] adapter) and translates its position /
/// duration / state stream into [TransportEvent]s.
///
/// `isLossless = true` because the local player decodes and renders
/// the original FLAC bytes — no transcode anywhere on the path.
class LocalTransport implements CastTransport {
  LocalTransport({
    required LocalAudioHandle player,
    String displayName = 'This device',
  })  : _player = player,
        _displayName = displayName {
    _wireStreams();
  }

  final LocalAudioHandle _player;
  final String _displayName;
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  Duration? _lastDuration;
  bool _disposed = false;

  @override
  String get id => 'local';

  @override
  String get displayName => _displayName;

  @override
  bool get isLossless => true;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> setTrack(Track t) async {
    _lastDuration = null;
    await _player.loadTrack(t);
  }

  @override
  Future<void> setNext(Track? t) => _player.setNext(t);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() async {
    await _player.pause();
    if (!_events.isClosed) {
      _events.add(TransportPaused(position: _player.position));
    }
  }

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  @override
  Future<void> stop() async {
    await _player.stop();
    if (!_events.isClosed) {
      _events.add(const TransportStopped());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _events.close();
    await _player.dispose();
  }

  void _wireStreams() {
    _subs.add(_player.durationStream.listen((d) {
      _lastDuration = d;
    }));
    _subs.add(_player.positionStream.listen((p) {
      if (_events.isClosed) return;
      if (_player.playing) {
        _events.add(
          TransportPlaying(position: p, duration: _lastDuration),
        );
      }
    }));
  }
}
