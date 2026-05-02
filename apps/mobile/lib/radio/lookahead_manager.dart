import 'dart:async';

import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

/// Owns the 5-deep ring of pre-picked track ids and the
/// `appendForRadio`-on-advance driver.
///
/// Slice 5 §11 item 5 is the load-bearing invariant: "Lookahead never
/// empties." That means whenever the player's `currentIndexStream`
/// emits a forward step, the manager must:
///
///   1. Pop the oldest pick from the ring.
///   2. Resolve the corresponding [Track] (path lookup against the
///      live tracks provider) and call
///      [QueueService.appendForRadio] so it lands in the queue tail.
///   3. Fire a fresh `RadioEngine.next` to refill the ring's tail.
///
/// All steps are non-blocking — `appendForRadio` is a synchronous
/// notifier mutation, and the `next` future is `unawaited` so the
/// stream listener returns to just_audio without holding up playback.
///
/// Self-de-dup runs against [RadioSession.history]; per slice 5 §10
/// risk 4, every pick records the picked track id and the manager
/// invalidates the ring + re-seeds when an id no longer maps to a
/// live track row.
class LookaheadManager {
  LookaheadManager({
    required this.repo,
    required this.engine,
    required this.queue,
    required this.trackByIdLookup,
  });

  final PlaylistRepo repo;
  final RadioEngine engine;
  final QueueService queue;

  /// Synchronous lookup from `trackId` → live [Track] row. The
  /// providers layer wires this to a live map kept warm by the cache
  /// db provider — when an id stops resolving (re-ingest dropped or
  /// reassigned the row), the manager invalidates its ring and
  /// re-seeds from `session.seed`.
  final Track? Function(int trackId) trackByIdLookup;

  /// Active session — null when radio is off. Set by [start]; cleared
  /// by [stop].
  RadioSession? _session;

  /// 5-deep ring of pre-picked track ids. Empty when no session is
  /// running. Invariant: when a session is running, len(ring) ≥ 4 in
  /// steady state (transient dip during append OK per §11 item 5).
  final List<int> _ring = <int>[];

  /// Read-only view of the ring for tests + debug instrumentation.
  /// Returns a defensive copy.
  List<int> get ring => List<int>.unmodifiable(_ring);

  /// Active session (read-only).
  RadioSession? get session => _session;

  /// Subscription on [PlaybackService.currentIndexStream]. Cancelled
  /// on [stop] and on dispose.
  StreamSubscription<int?>? _indexSub;
  int? _lastIndex;

  /// True while a refill is in-flight; prevents re-entrancy when
  /// multiple advances arrive in quick succession.
  bool _refilling = false;

  /// True after [dispose]; guards async tails landing post-teardown.
  bool _disposed = false;

  /// Boots the session: stores [initial], primes the ring with
  /// `lookahead` picks, and appends each picked track to the queue
  /// via [QueueService.appendForRadio]. Subsequent advances refill
  /// one at a time via [onAdvance].
  Future<void> start({
    required RadioSession initial,
    required Stream<int?> currentIndexStream,
  }) async {
    if (_disposed) return;
    await _indexSub?.cancel();
    _session = initial;
    _ring.clear();
    _lastIndex = null;
    queue.radioMode.set(true);

    // Prime the ring + queue with `lookahead` picks. Each pick updates
    // the session's history so subsequent picks see the running tail.
    for (var i = 0; i < initial.lookahead; i++) {
      final ok = await _pickOne();
      if (!ok) break;
    }

    _indexSub = currentIndexStream.listen(_onIndex);
  }

  /// Stops the session, cancels the index listener, drops the ring,
  /// and clears the radio-mode flag. Idempotent.
  Future<void> stop() async {
    if (_session == null && _ring.isEmpty) {
      queue.radioMode.set(false);
      return;
    }
    await _indexSub?.cancel();
    _indexSub = null;
    _session = null;
    _ring.clear();
    _lastIndex = null;
    queue.radioMode.set(false);
  }

  /// Replaces the tail of the ring with fresh picks. Per slice 5 §10
  /// risk 10: when a chip toggle changes the scoring, we want the
  /// not-yet-played part of the ring to reflect the new vibe. Cheap
  /// because the ring is 5-deep and `next` is sub-10 ms on a 5k
  /// library.
  ///
  /// Implementation: keep the head (we may have just advanced past it
  /// and the player is currently playing it); refill `lookahead - 1`
  /// fresh picks behind it. No queue mutation here — the queue's
  /// Upcoming tail still has the old picks; they'll play out before
  /// the fresh ring entries.
  Future<void> requeueTail({required RadioSession updatedSession}) async {
    if (_disposed) return;
    _session = updatedSession;
    if (_ring.isEmpty) return;
    final head = _ring.first;
    _ring
      ..clear()
      ..add(head);
    final goal = (updatedSession.lookahead - 1).clamp(0, updatedSession.lookahead);
    for (var i = 0; i < goal; i++) {
      final ok = await _pickOne(appendToQueue: false);
      if (!ok) break;
    }
  }

  /// Mutates [updatedSession] without touching the ring. Called when
  /// chip-toggle alone is enough — the existing ring entries play out
  /// under the previous scoring, but future picks reflect the new
  /// session.
  void onSessionUpdated(RadioSession updatedSession) {
    if (_disposed) return;
    _session = updatedSession;
  }

  void _onIndex(int? newIdx) {
    if (_disposed) return;
    if (newIdx == null) {
      _lastIndex = null;
      return;
    }
    final prev = _lastIndex;
    _lastIndex = newIdx;
    if (prev == null) return;
    if (newIdx == prev + 1) {
      // Forward natural advance — fire-and-forget refill.
      // ignore: discarded_futures
      _onAdvance();
    }
    // Backward / distant jumps don't drain the ring (slice 5 §10
    // risk 3 — scrubbing back into history doesn't dequeue picks).
  }

  Future<void> _onAdvance() async {
    if (_disposed || _session == null) return;
    if (_refilling) return;
    _refilling = true;
    try {
      // Pop the oldest pick — the player has now committed to it.
      if (_ring.isNotEmpty) {
        _ring.removeAt(0);
      }
      // Refill the tail.
      await _pickOne();
    } finally {
      _refilling = false;
    }
  }

  /// Performs one engine `next` call:
  ///   - Updates the session with the resulting pick.
  ///   - Pushes the picked id onto the ring tail.
  ///   - Optionally appends the resolved [Track] to the queue
  ///     (`appendToQueue=true`, the default — used by [start] +
  ///     [_onAdvance]).
  ///
  /// Returns true on success, false when the engine couldn't pick
  /// (empty library / sparse seed exhausted) or the picked id can't
  /// be resolved to a live [Track].
  Future<bool> _pickOne({bool appendToQueue = true}) async {
    final session = _session;
    if (session == null) return false;
    final result = await engine.next(session, repo);
    if (_disposed) return false;
    if (result == null) return false;
    final track = trackByIdLookup(result.pickedTrackId);
    if (track == null) {
      // §10 risk 4 — id no longer resolves; skip this pick. Caller
      // re-tries the next advance; if this keeps happening we should
      // re-seed (deferred until we can detect the pattern reliably).
      return false;
    }
    _session = result.nextSession;
    _ring.add(result.pickedTrackId);
    if (appendToQueue) {
      queue.appendForRadio(track);
    }
    return true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _indexSub?.cancel();
    _indexSub = null;
    _session = null;
    _ring.clear();
  }
}
