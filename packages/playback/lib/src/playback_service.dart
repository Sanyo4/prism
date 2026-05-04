import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';

import 'audio_player_port.dart';
import 'cast/local_player_handle.dart';
import 'queue_service.dart';

// ---------------------------------------------------------------------------
// Fade-in constants (slice-10b §A6)
// ---------------------------------------------------------------------------
//
// 40 ms linear ramp: 8 steps × 5 ms.  Below the ~50 ms human attack-time
// threshold, so the listener doesn't perceive a fade — it just suppresses
// the click/pop that comes from ExoPlayer starting decode at the *previous*
// track's gain level for 10–30 ms before the new `setVolume` lands.
const int _fadeInSteps = 8;
const Duration _fadeInStepDuration = Duration(milliseconds: 5);

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
///
/// Slice 9 added the **transport seam**. Every `play / pause / seek /
/// setTrack / setNext` delegates to a `currentTransport` —
/// [LocalTransport] by default (wraps the slice-1 player so behaviour
/// is byte-identical), [DlnaTransport] when the user picks a DLNA
/// receiver in the cast sheet, [ChromecastTransport] (Android only)
/// for Chromecast. Swapping is a `setTransport(...)` call that
/// preserves position + playing flag across the swap.
///
/// `syncSnapshot` keeps driving the local [AudioPlayerPort] directly
/// regardless of which transport is active. The local player remains
/// the source of truth for queue state — when DLNA / Chromecast is
/// active the local player is paused, but its `currentIndex` /
/// `currentIndexStream` continue to track snapshot changes so the
/// queue's `advance` / `retreat` semantics are unchanged. Swapping
/// back to Local is a single transport swap; the player resumes from
/// its preserved playhead.
class PlaybackService {
  /// Slice-1 backward-compat constructor. Constructs a default
  /// [LocalTransport] over the supplied or auto-built [player]. The
  /// slice-1 surface (`syncSnapshot`, fast-path mutators, ReplayGain
  /// volume application) is unchanged; the slice-9 surface (`play /
  /// pause / seek / setTrack / setNext / setTransport`) routes
  /// through the wrapping `LocalTransport`.
  ///
  /// Slice-1's 46 `playback_service_test` tests construct via this
  /// signature; they pass byte-identical because the `LocalTransport`
  /// path is a one-call passthrough to the underlying port.
  PlaybackService({
    AudioPlayerPort? player,
    bool replayGainEnabled = true,
    this.onAdvance,
    this.onRetreat,
    this.measuredReplayGainLookup,
  })  : _player = player ?? JustAudioPlayerPort(),
        _replayGainEnabled = replayGainEnabled {
    _currentTransport = LocalTransport(player: LocalPlayerHandle(_player));
    _indexSub = _player.currentIndexStream.listen(_onPlayerIndexChanged);
  }

  /// Slice-9 native constructor. Used by `apps/mobile`'s provider
  /// layer to inject an externally-constructed `LocalTransport` (so
  /// the same `AudioPlayerPort` instance is shared across the
  /// transport seam). The transport must wrap an `AudioPlayerPort`
  /// reachable via [audioPlayerPort] — `syncSnapshot`'s fast-path
  /// mutators address that port directly, not via the duck-typed
  /// `LocalAudioHandle` surface.
  PlaybackService.withTransport({
    required CastTransport currentTransport,
    required AudioPlayerPort audioPlayerPort,
    bool replayGainEnabled = true,
    this.onAdvance,
    this.onRetreat,
    this.measuredReplayGainLookup,
  })  : _player = audioPlayerPort,
        _replayGainEnabled = replayGainEnabled {
    _currentTransport = currentTransport;
    _indexSub = _player.currentIndexStream.listen(_onPlayerIndexChanged);
  }

  final AudioPlayerPort _player;
  bool _replayGainEnabled;

  /// Active transport. Always non-null after construction.
  late CastTransport _currentTransport;

  StreamSubscription<TransportEvent>? _transportEventsSub;

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

  // ---------------------------------------------------------------------------
  // Slice-10b §A6: fade-in state
  // ---------------------------------------------------------------------------
  /// Active fade-in timer; cancelled on the next track-switch so a rapid
  /// sequence of switches doesn't stack ramps.
  Timer? _fadeInTimer;

  /// Target gain for the in-flight fade-in (linear, 0..1). When the ramp
  /// completes this matches the persistent ReplayGain volume; during the ramp
  /// it's the destination value.
  double _fadeInTarget = 1.0;

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
  ///
  /// Slice-10b §A6: when the active Track changes between [prev] and [next],
  /// the service pre-sets the player volume to 0.0 BEFORE the source-switch
  /// so ExoPlayer starts decoding the new source silently, then schedules a
  /// 40 ms linear fade-in to the target ReplayGain volume (8 × 5 ms steps).
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

    final trackChanged = prev.current != next.current;

    if (_flatListsMatch(prev.flat, next.flat)) {
      if (prev.currentIndex != next.currentIndex) {
        // Same flat list but a different active index → jumping to another
        // pre-loaded source. ExoPlayer switches the active MediaSource, so
        // the same pre-decode volume glitch applies. Apply fade-in.
        if (trackChanged) {
          _fadeInTimer?.cancel();
          _fadeInTarget = _resolveTargetVolume(next.current);
          await _player.setVolume(0.0);
        }
        _syncing = true;
        try {
          await _player.seek(Duration.zero, index: next.currentIndex);
        } finally {
          _syncing = false;
        }
        if (trackChanged) {
          _scheduleFadeIn();
        } else {
          await _applyReplayGain(next.current);
        }
      } else {
        // Pure emission — same flat, same index. Volume sync only.
        await _applyReplayGain(next.current);
      }
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
        // Active track unchanged — no fade needed, just sync volume.
        await _applyReplayGain(next.current);
        _emitCurrentTrack();
        return;
      }
    }

    // Rebuild path.  When the active track changes, pre-set volume to 0.0
    // before the setAudioSources call, then schedule the fade-in after.
    final wasPlaying = _player.playing;
    final resumeFrom = activePreserved ? _player.position : Duration.zero;

    if (trackChanged) {
      _fadeInTimer?.cancel();
      _fadeInTarget = _resolveTargetVolume(next.current);
      await _player.setVolume(0.0);
    }

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

    if (trackChanged) {
      _scheduleFadeIn();
    } else {
      await _applyReplayGain(next.current);
    }
    _emitCurrentTrack();
  }

  /// Resolves the target linear volume for [track] using the same precedence
  /// logic as [_applyReplayGain]: measured (sidecar cache) wins over tag RG.
  double _resolveTargetVolume(Track? track) {
    final measured =
        track == null ? null : measuredReplayGainLookup?.call(track);
    return resolveVolume(
      enabled: _replayGainEnabled,
      replayGainTrackDb: measured ?? track?.replayGainTrackDb,
    );
  }

  /// Schedules an 8-step × 5 ms linear fade-in from 0.0 to [_fadeInTarget].
  /// Any in-flight fade is already cancelled by the caller before this runs.
  void _scheduleFadeIn() {
    var step = 0;
    _fadeInTimer = Timer.periodic(_fadeInStepDuration, (t) {
      step++;
      if (step >= _fadeInSteps) {
        t.cancel();
        _fadeInTimer = null;
        // ignore: discarded_futures
        _player.setVolume(_fadeInTarget);
        return;
      }
      // ignore: discarded_futures
      _player.setVolume(_fadeInTarget * step / _fadeInSteps);
    });
  }

  /// Currently active transport. The default after construction is a
  /// [LocalTransport] wrapping the slice-1 [AudioPlayerPort];
  /// [setTransport] swaps to a different transport (DLNA / Chromecast)
  /// while preserving position + playing flag.
  CastTransport get currentTransport => _currentTransport;

  /// Slice-9 surface — delegates to [currentTransport].
  Future<void> play() => _currentTransport.play();

  /// Slice-9 surface — delegates to [currentTransport].
  Future<void> pause() => _currentTransport.pause();

  /// Slice-9 surface — delegates to [currentTransport].
  Future<void> seek(Duration position) => _currentTransport.seek(position);

  /// Slice-9 surface — delegates to [currentTransport]. The mobile UI
  /// calls this when the active track changes during a remote-transport
  /// session so the receiver picks up the new source. In a local-only
  /// session, [syncSnapshot] handles this implicitly via the underlying
  /// port's source-list mutators.
  Future<void> setTrack(Track t) => _currentTransport.setTrack(t);

  /// Slice-9 surface — queues the next track on [currentTransport].
  /// Pass `null` to clear. The DLNA implementation forwards via
  /// `SetNextAVTransportURI`; Local writes to the player's queue tail.
  Future<void> setNext(Track? t) => _currentTransport.setNext(t);

  /// Swap [currentTransport] to [next]. Preserves the player's
  /// position + playing flag across the swap so audible state is
  /// continuous up to the receiver / device handoff latency.
  ///
  /// Lifecycle:
  /// 1. Snapshot position + playing flag from the local player (the
  ///    canonical playhead — DLNA / Cast transports lag the local
  ///    state by their poll cadence).
  /// 2. Pause the previous transport. For [LocalTransport] this
  ///    pauses the underlying player; for remote transports it
  ///    sends `Pause` over the wire.
  /// 3. Replace `_currentTransport` with [next]; re-subscribe to
  ///    its `events` stream.
  /// 4. If a current track is loaded, `setTrack(track) → seek(pos) →
  ///    play()` on the new transport (skipping `play()` if the
  ///    previous transport was paused at swap time).
  /// 5. Dispose the previous transport, except when it was a
  ///    [LocalTransport] — those wrap the slice-1 port which
  ///    PlaybackService still owns and may re-wrap on a future
  ///    swap back to Local.
  Future<void> setTransport(CastTransport next) async {
    if (_disposed) return;
    if (identical(_currentTransport, next)) return;

    final wasPlaying = _player.playing;
    final position = _player.position;
    final track = _snapshot.current;
    final old = _currentTransport;

    await old.pause();
    // Belt-and-suspenders: if the old transport was non-Local, the
    // local player may still be reflecting the previous Local
    // session's "playing" flag. Force-pause so the OS audio stack
    // doesn't double-source if the user rapidly swaps Local → DLNA →
    // Local.
    if (_player.playing) {
      await _player.pause();
    }

    await _transportEventsSub?.cancel();
    _currentTransport = next;
    _transportEventsSub = next.events.listen(_onTransportEvent);

    if (track != null) {
      await next.setTrack(track);
      await next.seek(position);
      if (wasPlaying) {
        await next.play();
      }
    }

    // Dispose the previous transport so its subscriptions / SOAP
    // poll loop / Cast session release. The slice-9 [LocalPlayerHandle]
    // adapter explicitly defines its `dispose()` as a no-op so
    // [LocalTransport.dispose()]'s call to `_player.dispose()`
    // does NOT tear down the underlying [AudioPlayerPort] — the port
    // outlives the transport so a swap back to Local can reuse it.
    await old.dispose();
  }

  void _onTransportEvent(TransportEvent ev) {
    // Slice 9 hook for downstream consumers: today this is a no-op.
    // The DLNA / Chromecast transports surface position updates here;
    // when slice-9 §11 step 13 (gapless handoff via setNext on
    // remaining < 5 s) lands, this listener computes the threshold
    // and dispatches `setNext(peekAfter)`. For now keep it open so
    // the subscription stays warm.
  }

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
  /// the underlying [AudioPlayerPort]. Also disposes the active
  /// transport's network handles when it's a non-Local one.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Cancel any in-flight fade-in so the periodic Timer doesn't fire
    // after the player is torn down.
    _fadeInTimer?.cancel();
    _fadeInTimer = null;
    await _indexSub?.cancel();
    _indexSub = null;
    await _transportEventsSub?.cancel();
    _transportEventsSub = null;
    final transport = _currentTransport;
    // For LocalTransport, the underlying port is owned by
    // PlaybackService and disposed below; the transport's own
    // dispose() is harmless (clears its internal subscriptions). For
    // remote transports, dispose() releases the SOAP poll loop or
    // Cast session in addition.
    await transport.dispose();
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
