import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';

import '../audio_player_port.dart';

/// Adapter that translates an [AudioPlayerPort] into the
/// structural [LocalAudioHandle] interface that
/// [LocalTransport] (in `prism_cast`) consumes.
///
/// Slice 9 §3 forbids `prism_cast` from importing `prism_playback`
/// (the dep would form a cycle — `prism_playback` consumes
/// `CastTransport` from `prism_cast`). Track A's `LocalAudioHandle`
/// is the duck-typed surface that lets `LocalTransport` wrap the
/// slice-1 player without the cycle. This adapter lives in
/// `prism_playback` and is the only translation surface.
///
/// **Lifecycle**
/// - The adapter does **not** own the [AudioPlayerPort]. The
///   PlaybackService that constructs both the port and the
///   adapter is responsible for `port.dispose()`. The adapter's
///   own `dispose()` is a no-op so that swapping transports
///   (Local → DLNA → Local) doesn't repeatedly close + reopen
///   the underlying `just_audio` instance.
/// - The adapter is cheap (no buffers, no subscriptions of its own).
///   PlaybackService can construct a fresh adapter on every
///   `setTransport(LocalTransport(...))` call.
class LocalPlayerHandle implements LocalAudioHandle {
  LocalPlayerHandle(this._port);

  final AudioPlayerPort _port;

  /// The wrapped port. PlaybackService reads this back when it
  /// wants to drive `syncSnapshot`'s slice-1 fast-path mutators
  /// (`insertAudioSource`, `moveAudioSource`, `removeAudioSourceAt`)
  /// directly — those live on `AudioPlayerPort`, not on the
  /// duck-typed `LocalAudioHandle`.
  AudioPlayerPort get port => _port;

  @override
  bool get playing => _port.playing;

  @override
  Duration get position => _port.position;

  @override
  Stream<Duration> get positionStream => _port.positionStream;

  @override
  Stream<Duration?> get durationStream => _port.durationStream;

  @override
  Future<void> loadTrack(Track t) =>
      _port.setAudioSources(<AudioSource>[AudioSource.uri(Uri.file(t.path))]);

  @override
  Future<void> setNext(Track? t) async {
    if (t == null) {
      // Best-effort clear: the slice-1 port doesn't surface a
      // "drop everything past current" mutator. We leave the queue
      // tail in place — the queueProvider listener will reconcile
      // on the next snapshot via the fast-path remove dispatch.
      return;
    }
    final cur = _port.currentIndex;
    final insertIndex = (cur ?? 0) + 1;
    await _port.insertAudioSource(
      insertIndex,
      AudioSource.uri(Uri.file(t.path)),
    );
  }

  @override
  Future<void> play() => _port.play();

  @override
  Future<void> pause() => _port.pause();

  @override
  Future<void> seek(Duration to) => _port.seek(to);

  @override
  Future<void> stop() => _port.pause();

  @override
  Future<void> dispose() async {
    // Intentional no-op: the underlying `AudioPlayerPort` is owned
    // by PlaybackService, not by the adapter. Disposing here would
    // tear down the just_audio instance and break a subsequent
    // swap back to a fresh LocalTransport over the same port.
  }
}
