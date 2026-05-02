import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:prism_core/core.dart';

import 'audio_player_port.dart';
import 'queue_service.dart';

/// Thin shim around an [AudioPlayerPort] that keeps the
/// player in lock-step with [QueueService]'s three-zone snapshot.
///
/// Responsibilities:
/// - **Forward the queue** to the backend via the narrowest op that
///   expresses the change:
///     - Flat unchanged → `seek` when `currentIndex` shifted, else
///       a pure emission.
///     - Active track preserved, single-element change →
///       `insertAudioSource` / `removeAudioSourceAt` /
///       `moveAudioSource`. The backend keeps the active source
///       playing without resetting its playhead — no audible glitch.
///     - Everything else (`loadContext`, active-track change,
///       multi-element shuffle) → `setAudioSources` rebuild. Audibly
///       pauses briefly on ExoPlayer; accepted because the user has
///       explicitly changed contexts.
/// - **Mirror natural playback**: when `currentIndexStream` emits
///   `prev + 1` we fire [onAdvance] (callers wire this to
///   `QueueService.advance`). `prev - 1` fires [onRetreat]. Distant
///   jumps come from our own `setAudioSources` / `seek` calls and
///   are guarded by [_syncing].
/// - **Apply ReplayGain**: after every sync, `setVolume` to
///   `dbToLinear(track.replayGainTrackDb)` clamped to `[0, 1]` when
///   RG is enabled, otherwise `1.0`. The setter short-circuits on
///   unchanged values so fast-path syncs don't ping the channel.
///
/// The diff-based fast paths were originally scheduled for slice 5
/// (radio append). Pulled forward into slice 1 because slice 1's
/// common `loadContext(allTracks, …)` plus the three-zone queue ops
/// together produce a multi-thousand-entry flat projection — a full
/// `setAudioSources` rebuild per UI action was causing audible
/// stutter on user-initiated queue mutations while playing.
///
/// What this service still does **not** do:
/// - Non-adjacent multi-element reorders as a single op. A move that
///   doesn't match the single-shift pattern falls to the rebuild
///   path — rare in slice 1's UI (only `_jumpToHere` across a large
///   gap triggers it), and that flow already implies a perceptual
///   context shift.
///
/// Slice 4 added: optional [measuredReplayGainLookup] hook so the
/// service can prefer measured RG (from the sidecar cache) over tag
/// RG. The lookup is **synchronous** — callers are expected to
/// pre-warm a cache off the active track and feed back a value that
/// resolves immediately. We avoid plumbing a `Future<double?>` through
/// because volume must apply on the same frame as the source switch
/// to avoid an audible volume bump on the first sample.
class PlaybackService {
  PlaybackService({
    AudioPlayerPort? player,
    bool replayGainEnabled = true,
    this.onAdvance,
    this.onRetreat,
    this.measuredReplayGainLookup,
  })  : _player = player ?? JustAudioPlayerPort(),
        _replayGainEnabled = replayGainEnabled {
    _indexSub = _player.currentIndexStream.listen(_onPlayerIndexChanged);
  }

  final AudioPlayerPort _player;
  bool _replayGainEnabled;

  /// Synchronous lookup: given a [Track], return the measured (sidecar)
  /// `replaygain_track_db` if the corresponding row is `status='ready'`
  /// in the cache, else `null`. The service prefers this over
  /// [Track.replayGainTrackDb] when non-null.
  ///
  /// Slice-4 wires this from `apps/mobile/lib/providers/cache_db_providers.dart`
  /// — it's a pure path → double lookup against an in-memory map kept
  /// warm by an ingest provider.
  final double? Function(Track track)? measuredReplayGainLookup;

  /// Invoked when the backend's index moves forward exactly one step,
  /// signalling that the previous track finished naturally. Typical
  /// wiring: `() => ref.read(queueProvider.notifier).advance()`.
  final void Function()? onAdvance;

  /// Invoked when the backend's index moves backward one step, e.g.
  /// after `skipToPrevious`. Typical wiring:
  /// `() => ref.read(queueProvider.notifier).retreat()`.
  final void Function()? onRetreat;

  QueueSnapshot _snapshot = const QueueSnapshot.empty();
  bool _syncing = false;
  StreamSubscription<int?>? _indexSub;
  final StreamController<Track?> _currentTrackController =
      StreamController<Track?>.broadcast();
  bool _disposed = false;

  /// Last snapshot the service has sync'd with the backend. Exposed
  /// for tests and for the Notifier bridge in step 10 that needs to
  /// publish `MediaItem`s without a second listener.
  QueueSnapshot get snapshot => _snapshot;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;

  /// Synchronous snapshot of the backend playhead. Needed by the
  /// `PrismAudioHandler` bridge when stamping `PlaybackState.updatePosition`
  /// on state transitions — `audio_service` extrapolates between
  /// transitions from this anchor.
  Duration get position => _player.position;

  /// Whether the backend is in the "requested to play" state.
  bool get playing => _player.playing;

  /// Combined `(snapshot, currentIndex)` → `Track?` stream. The UI
  /// subscribes here rather than cross-referencing two streams.
  Stream<Track?> get currentTrackStream => _currentTrackController.stream;

  /// Whether the service is applying tag-embedded ReplayGain to the
  /// player's output volume. Toggle via [setReplayGainEnabled].
  bool get replayGainEnabled => _replayGainEnabled;

  /// Synchronises the backend with [next]. Called by the
  /// `playbackServiceProvider` on every `queueProvider` change.
  ///
  /// Branches (narrowest first):
  /// 1. `next.current == null` → drained queue, pause the backend.
  /// 2. Flat projection unchanged → seek when `currentIndex` shifted,
  ///    else a no-op. The player keeps its source list untouched.
  /// 3. Active track preserved and the flat diff reduces to a single
  ///    insert / remove / move → dispatch to the matching port mutator
  ///    (`insertAudioSource`, `removeAudioSourceAt`, `moveAudioSource`).
  ///    The current source continues playing; just_audio adjusts its
  ///    `currentIndex` internally to track it.
  /// 4. Everything else → `setAudioSources` rebuild. Preserves the
  ///    playhead only when the active track's identity is unchanged —
  ///    anything else would splice audio mid-track which reads as a
  ///    glitch.
  Future<void> syncSnapshot(QueueSnapshot next) async {
    final prev = _snapshot;
    _snapshot = next;

    if (next.current == null) {
      if (_player.playing) {
        await _player.pause();
      }
      _emitCurrentTrack();
      return;
    }

    if (_flatListsMatch(prev.flat, next.flat)) {
      if (prev.currentIndex != next.currentIndex) {
        _syncing = true;
        try {
          await _player.seek(Duration.zero, index: next.currentIndex);
        } finally {
          _syncing = false;
        }
      }
      await _applyReplayGain(next.current);
      _emitCurrentTrack();
      return;
    }

    // Fast path: single-element diff while the active track stays put.
    // Active identity is compared by [Track.path] (see `Track.==`), so
    // the same file re-projected across zones counts as unchanged.
    final activePreserved =
        prev.current != null && prev.current == next.current;
    if (activePreserved) {
      final diff = _classifyFlatDiff(prev.flat, next.flat);
      if (diff != null && !_diffRemovesActive(diff, prev.currentIndex)) {
        _syncing = true;
        try {
          switch (diff) {
            case _FlatInsert(:final index, :final track):
              await _player.insertAudioSource(
                index,
                AudioSource.uri(Uri.file(track.path)),
              );
            case _FlatRemove(:final index):
              await _player.removeAudioSourceAt(index);
            case _FlatMove(:final from, :final to):
              await _player.moveAudioSource(from, to);
          }
        } finally {
          _syncing = false;
        }
        await _applyReplayGain(next.current);
        _emitCurrentTrack();
        return;
      }
    }

    // Rebuild path.
    final wasPlaying = _player.playing;
    final resumeFrom = activePreserved ? _player.position : Duration.zero;

    final sources = <AudioSource>[
      for (final t in next.flat) AudioSource.uri(Uri.file(t.path)),
    ];

    _syncing = true;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: next.currentIndex,
        initialPosition: resumeFrom,
      );
      if (wasPlaying) {
        await _player.play();
      }
    } finally {
      _syncing = false;
    }
    await _applyReplayGain(next.current);
    _emitCurrentTrack();
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position) => _player.seek(position);

  /// Advances the queue via [onAdvance]; the resulting
  /// `syncSnapshot` reseeks the player. Does **not** call
  /// `player.seekToNext` directly — the player's source list stays
  /// aligned with the snapshot's flat projection across
  /// advance / retreat, so a queue-driven seek is sufficient and
  /// keeps the two sides from racing.
  Future<void> skipToNext() async {
    if (_snapshot.current == null) return;
    onAdvance?.call();
  }

  /// Retreats the queue via [onRetreat]; `syncSnapshot` then seeks
  /// the player backward to match. See [skipToNext] for the reason
  /// we don't call the backend's seekToPrevious directly.
  Future<void> skipToPrevious() async {
    if (_snapshot.history.isEmpty) return;
    onRetreat?.call();
  }

  /// Flips tag-embedded ReplayGain application on or off. Reapplies
  /// immediately so the change is audible without waiting for the
  /// next track.
  Future<void> setReplayGainEnabled(bool on) async {
    if (_replayGainEnabled == on) return;
    _replayGainEnabled = on;
    await _applyReplayGain(_snapshot.current);
  }

  /// Releases the stream subscription, the broadcast controller, and
  /// the underlying [AudioPlayerPort].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _indexSub?.cancel();
    _indexSub = null;
    await _currentTrackController.close();
    await _player.dispose();
  }

  void _onPlayerIndexChanged(int? newIdx) {
    if (_disposed) return;
    // Programmatic jumps (our own setAudioSources / seek) are wrapped
    // in _syncing so we don't treat them as natural playback moves.
    if (_syncing) {
      _emitCurrentTrack();
      return;
    }
    if (newIdx == null) {
      _emitCurrentTrack();
      return;
    }
    final snap = _snapshot;
    if (snap.current == null) {
      _emitCurrentTrack();
      return;
    }
    final oldIdx = snap.currentIndex;
    if (newIdx == oldIdx + 1) {
      onAdvance?.call();
    } else if (newIdx == oldIdx - 1) {
      onRetreat?.call();
    }
    // Distant jumps or equal index → no queue mutation; the emission
    // typically arrives from a sync we drove.
    _emitCurrentTrack();
  }

  void _emitCurrentTrack() {
    if (_disposed) return;
    final snap = _snapshot;
    final idx = _player.currentIndex;
    Track? track;
    if (idx != null && idx >= 0 && idx < snap.flat.length) {
      track = snap.flat[idx];
    }
    _currentTrackController.add(track);
  }

  Future<void> _applyReplayGain(Track? track) async {
    // Slice-4 precedence: measured (cache, status='ready') wins over
    // tag-embedded. `null` from the lookup falls through to the tag.
    final measured =
        track == null ? null : measuredReplayGainLookup?.call(track);
    final linear = resolveVolume(
      enabled: _replayGainEnabled,
      replayGainTrackDb: measured ?? track?.replayGainTrackDb,
    );
    if (_player.volume == linear) return;
    await _player.setVolume(linear);
  }

  /// Pure helper: converts a `REPLAYGAIN_TRACK_GAIN` (dB) — measured
  /// or tag-embedded — to the linear scale factor `setVolume` expects,
  /// clamped to `[0, 1]`. When [enabled] is false or both inputs are
  /// absent, returns `1.0` (full-scale pass-through).
  ///
  /// Exposed as a static so tests can assert the mapping without a
  /// player.
  static double resolveVolume({
    required bool enabled,
    required double? replayGainTrackDb,
  }) {
    if (!enabled || replayGainTrackDb == null) return 1.0;
    final linear = dbToLinear(replayGainTrackDb);
    return linear.clamp(0.0, 1.0);
  }

  /// Identity-only comparison for the flat projection. Track equality
  /// is by [Track.path] (see `Track.==`) so comparing lengths + each
  /// slot is O(N) in the flat length — cheap relative to the
  /// alternative of rebuilding the player's source list.
  static bool _flatListsMatch(List<Track> a, List<Track> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Removing the active index mid-playback would silence the player
  /// and require a re-seek to whatever the queue chose as the new
  /// active; cleaner to fall back to [setAudioSources] with an
  /// explicit `initialIndex`. All other single-element ops keep the
  /// current source playing — just_audio adjusts its `currentIndex`
  /// internally to track the source through the mutation.
  ///
  /// Slice 1 doesn't have a UI path that removes the active track
  /// anyway (`QueueService.removeAt` short-circuits on the current
  /// zone), but we guard here for future slices that might.
  static bool _diffRemovesActive(_FlatDiff diff, int prevCurrentIndex) {
    if (diff is _FlatRemove) {
      return diff.index == prevCurrentIndex;
    }
    return false;
  }

  /// Detects the narrowest single-element shape that turns `prev` into
  /// `next`: insert at one index, remove at one index, or a single
  /// contiguous move. Returns `null` for wider diffs (multi-element
  /// shuffle, unrelated list) — the caller falls back to
  /// [setAudioSources]. O(N) in the list length; track equality is by
  /// [Track.path].
  static _FlatDiff? _classifyFlatDiff(List<Track> prev, List<Track> next) {
    // Insert: next is prev with one extra element wedged in.
    if (next.length == prev.length + 1) {
      var i = 0;
      while (i < prev.length && prev[i] == next[i]) {
        i++;
      }
      for (var j = i; j < prev.length; j++) {
        if (prev[j] != next[j + 1]) return null;
      }
      return _FlatInsert(i, next[i]);
    }

    // Remove: prev is next with one extra element wedged in.
    if (next.length == prev.length - 1) {
      var i = 0;
      while (i < next.length && prev[i] == next[i]) {
        i++;
      }
      for (var j = i; j < next.length; j++) {
        if (prev[j + 1] != next[j]) return null;
      }
      return _FlatRemove(i);
    }

    // Move: same length, one element shifted to a new slot. Two shapes:
    // right-move (element at `first` migrated to `last`) or left-move
    // (element at `last` migrated to `first`). Both produce the same
    // final list for adjacent swaps; either answer is fine in that
    // degenerate case.
    if (next.length == prev.length) {
      var first = 0;
      while (first < prev.length && prev[first] == next[first]) {
        first++;
      }
      if (first == prev.length) return null; // identical — caller handled
      var last = prev.length - 1;
      while (last > first && prev[last] == next[last]) {
        last--;
      }

      // Right-move: prev[first] is the moved element, now at next[last].
      if (next[last] == prev[first]) {
        var ok = true;
        for (var k = first; k < last; k++) {
          if (next[k] != prev[k + 1]) {
            ok = false;
            break;
          }
        }
        if (ok) return _FlatMove(first, last);
      }

      // Left-move: prev[last] is the moved element, now at next[first].
      if (next[first] == prev[last]) {
        var ok = true;
        for (var k = first + 1; k <= last; k++) {
          if (next[k] != prev[k - 1]) {
            ok = false;
            break;
          }
        }
        if (ok) return _FlatMove(last, first);
      }
    }

    return null;
  }
}

/// Tag describing the narrowest operation that turns one flat
/// projection into another. Consumed by `syncSnapshot`'s fast path;
/// anything wider (multi-element shuffle, active-track change) skips
/// classification entirely and falls to `setAudioSources`.
sealed class _FlatDiff {
  const _FlatDiff();
}

class _FlatInsert extends _FlatDiff {
  const _FlatInsert(this.index, this.track);
  final int index;
  final Track track;
}

class _FlatRemove extends _FlatDiff {
  const _FlatRemove(this.index);
  final int index;
}

class _FlatMove extends _FlatDiff {
  const _FlatMove(this.from, this.to);
  final int from;
  final int to;
}
