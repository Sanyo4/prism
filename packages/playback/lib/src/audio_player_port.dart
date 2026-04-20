import 'package:just_audio/just_audio.dart';

/// Narrow port exposing just the `just_audio.AudioPlayer` surface that
/// `PlaybackService` needs. Lets the service be unit-tested without
/// the `just_audio` platform channel (which is not available under
/// `flutter_test`) and gives slice 9 (Cast / DLNA) a seam to swap the
/// whole backend.
///
/// Keep this strictly in sync with the subset the service actually
/// calls — enlarging the surface costs every alternate backend a new
/// method. Adding fields here should always come with a comment
/// explaining why slice N needs it.
abstract class AudioPlayerPort {
  /// Current linear output volume in `[0, 1]`. Seeded to `1.0` by
  /// `just_audio` (full scale). Read in tests to assert ReplayGain
  /// application.
  double get volume;

  /// Zero-based index into the source list supplied by
  /// [setAudioSources]. `null` before the first load and after
  /// `dispose`. Matches `QueueSnapshot.currentIndex` while playback
  /// is in sync.
  int? get currentIndex;

  /// `true` when the player is in the "requested to play" state, even
  /// if it is currently buffering. Independent of pause.
  bool get playing;

  /// Current playhead position within the active source.
  Duration get position;

  /// Emits the player's [currentIndex] as it changes.
  /// `PlaybackService` listens to detect natural advance past
  /// [QueueSnapshot.currentIndex] so it can drive `advance()` on the
  /// queue.
  Stream<int?> get currentIndexStream;

  /// Emits the playhead position at the backend's ticking rate.
  Stream<Duration> get positionStream;

  /// Emits the duration of the active source when it becomes known
  /// (some sources emit `null` while loading).
  Stream<Duration?> get durationStream;

  /// Emits on `playing` and `processingState` transitions.
  Stream<PlayerState> get playerStateStream;

  /// Replaces the current source list and optionally seeks to
  /// [initialIndex] at [initialPosition]. Full rebuild — tears down
  /// the backend's MediaSource, audibly glitches mid-stream. Use the
  /// single-element mutators below when the diff is expressible that
  /// way. Originally scheduled for slice 5; pulled forward into slice
  /// 1 because the flat source list can grow to ~library-size when
  /// `TracksScreen.loadContext(allTracks, …)` is the common case.
  Future<void> setAudioSources(
    List<AudioSource> audioSources, {
    int? initialIndex,
    Duration? initialPosition,
  });

  /// Inserts [source] at [index] in the current source list without
  /// disrupting playback. Indices at or before the active index shift
  /// it right by one; the active source continues playing uninterrupted.
  Future<void> insertAudioSource(int index, AudioSource source);

  /// Removes the source at [index] from the current source list.
  /// Removing a non-active index keeps playback going; removing the
  /// active index is out of scope for slice 1 (no UI path hits it —
  /// `QueueService.removeAt` short-circuits on the current zone).
  Future<void> removeAudioSourceAt(int index);

  /// Moves the source from [from] to [to] without disrupting playback.
  /// Used for `move up` / `move down` / drag-reorder flows; the active
  /// track stays playing and its playhead is preserved.
  Future<void> moveAudioSource(int from, int to);

  Future<void> play();
  Future<void> pause();

  /// Seeks to [position] in the currently-active source, or to
  /// [position] of source [index] when [index] is supplied. Used by
  /// the service to realign the player when the queue's
  /// `currentIndex` changes without the flat projection changing
  /// (advance / retreat, user-driven skip-next / skip-previous).
  Future<void> seek(Duration position, {int? index});

  /// Sets output gain as a linear scale factor in `[0, 1]`.
  /// `PlaybackService.dbToLinear(rg)` feeds this; out-of-range
  /// values are clamped by the service, not the port.
  Future<void> setVolume(double volume);

  Future<void> dispose();
}

/// Thin adapter wrapping a `just_audio.AudioPlayer`. Used in
/// production; tests substitute their own [AudioPlayerPort].
class JustAudioPlayerPort implements AudioPlayerPort {
  JustAudioPlayerPort({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  double get volume => _player.volume;

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  bool get playing => _player.playing;

  @override
  Duration get position => _player.position;

  @override
  Stream<int?> get currentIndexStream => _player.currentIndexStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  @override
  Future<void> setAudioSources(
    List<AudioSource> audioSources, {
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    await _player.setAudioSources(
      audioSources,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource source) =>
      _player.insertAudioSource(index, source);

  @override
  Future<void> removeAudioSourceAt(int index) =>
      _player.removeAudioSourceAt(index);

  @override
  Future<void> moveAudioSource(int from, int to) =>
      _player.moveAudioSource(from, to);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() => _player.dispose();
}
