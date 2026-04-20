import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart';

/// `audio_service` <-> `PlaybackService` bridge.
///
/// `audio_service` owns the foreground-service + media-notification
/// plumbing (lockscreen, auto, wear, MPRIS on Linux). It reaches into
/// our app by calling the handler's `play`/`pause`/`seek`/`skipTo*`
/// methods and by listening to the handler's `mediaItem` and
/// `playbackState` subjects. Both sides are already designed for that
/// shape — this class just adapts one to the other.
///
/// Outbound (service → OS):
/// - `currentTrackStream` + `durationStream` → `mediaItem` (title,
///   artist, album, duration).
/// - `playerStateStream` → `playbackState` (processing + playing
///   + controls). The update position is sampled from
///   `PlaybackService.position` at each transition; the OS
///   interpolates between transitions.
///
/// Inbound (OS → service):
/// - `play` / `pause` / `seek` / `skipToNext` / `skipToPrevious` call
///   straight through. No local transport state is kept — the
///   `PlaybackService` is the single source of truth.
///
/// Slice 1 scope only: one [MediaItem] at a time (the current track).
/// Slice 2 can republish the whole `queue` subject if we want the
/// Android Auto queue UI. Cover art (`MediaItem.artUri`) lands in
/// slice 4 alongside sidecar thumbnails.
class PrismAudioHandler extends BaseAudioHandler {
  PrismAudioHandler(this._service) {
    _trackSub = _service.currentTrackStream.listen(_onCurrentTrack);
    _durationSub = _service.durationStream.listen(_onDuration);
    _stateSub = _service.playerStateStream.listen(_onPlayerState);
  }

  final PlaybackService _service;

  Track? _lastTrack;
  Duration? _lastDuration;

  late final StreamSubscription<Track?> _trackSub;
  late final StreamSubscription<Duration?> _durationSub;
  late final StreamSubscription<ja.PlayerState> _stateSub;

  // -- Transport: OS-initiated actions forwarded to PlaybackService. --

  @override
  Future<void> play() => _service.play();

  @override
  Future<void> pause() => _service.pause();

  @override
  Future<void> seek(Duration position) => _service.seek(position);

  @override
  Future<void> skipToNext() => _service.skipToNext();

  @override
  Future<void> skipToPrevious() => _service.skipToPrevious();

  @override
  Future<void> stop() async {
    await _service.pause();
    await super.stop();
  }

  // -- Outbound: service streams → audio_service subjects. --

  void _onCurrentTrack(Track? track) {
    _lastTrack = track;
    // Reset the cached duration when the track changes — the next
    // `durationStream` emission will repopulate it.
    _lastDuration = track?.duration;
    _emitMediaItem();
  }

  void _onDuration(Duration? duration) {
    _lastDuration = duration ?? _lastTrack?.duration;
    _emitMediaItem();
  }

  void _emitMediaItem() {
    final track = _lastTrack;
    if (track == null) {
      mediaItem.add(null);
      return;
    }
    mediaItem.add(MediaItem(
      id: track.path,
      title: track.title ?? _filenameWithoutExtension(track.path),
      album: track.album,
      artist: track.artist ?? track.albumArtist,
      genre: track.genre,
      duration: _lastDuration ?? track.duration,
    ));
  }

  void _onPlayerState(ja.PlayerState state) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (state.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapProcessingState(state.processingState),
      playing: state.playing,
      updatePosition: _service.position,
    ));
  }

  static AudioProcessingState _mapProcessingState(ja.ProcessingState s) {
    switch (s) {
      case ja.ProcessingState.idle:
        return AudioProcessingState.idle;
      case ja.ProcessingState.loading:
        return AudioProcessingState.loading;
      case ja.ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ja.ProcessingState.ready:
        return AudioProcessingState.ready;
      case ja.ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  /// Fallback display title when a track's tag is missing — the
  /// filename without its extension. Matches what Apple Music / Files
  /// show for untagged rips.
  static String _filenameWithoutExtension(String path) {
    final slash = path.lastIndexOf('/');
    final base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  /// Cancels the `PlaybackService` stream subscriptions. The service
  /// and the underlying player are disposed by whoever owns them
  /// (typically `ref.onDispose` of `playbackServiceProvider`).
  Future<void> detach() async {
    await _trackSub.cancel();
    await _durationSub.cancel();
    await _stateSub.cancel();
  }
}
