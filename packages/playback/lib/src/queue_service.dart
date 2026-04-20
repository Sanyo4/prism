import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'queue_zone.dart';

/// Immutable three-zone queue projection consumed by `PlaybackService`
/// and every queue-touching UI widget.
///
/// Layout of [flat]:
/// ```
///   [ ...history , current , ...playNext , ...upcoming ]
/// ```
///
/// Indices over [flat] are what `just_audio.setAudioSources(sources,
/// initialIndex: …)` consumes and what `QueueScreen` passes to
/// `move(from, to)`. When [current] is `null` (drained queue), [flat]
/// is just `[...history, ...playNext, ...upcoming]` and
/// [currentIndex] is `-1`.
class QueueSnapshot {
  final List<Track> history;
  final Track? current;
  final List<Track> playNext;
  final List<Track> upcoming;

  const QueueSnapshot({
    this.history = const <Track>[],
    this.current,
    this.playNext = const <Track>[],
    this.upcoming = const <Track>[],
  });

  const QueueSnapshot.empty() : this();

  /// Position of [current] in [flat], or `-1` if the queue is drained.
  int get currentIndex => current == null ? -1 : history.length;

  /// Flat projection in playback order. Rebuilt lazily per call — slice 1
  /// rebuilds the list on every snapshot; slice 5 can memoize if the
  /// append-heavy radio flow makes allocation dominate.
  List<Track> get flat => <Track>[
        ...history,
        ?current,
        ...playNext,
        ...upcoming,
      ];

  /// Total number of entries across all zones, counting [current] when
  /// present.
  int get length =>
      history.length +
      (current == null ? 0 : 1) +
      playNext.length +
      upcoming.length;

  bool get isEmpty => length == 0;

  /// Which zone the entry at [flatIndex] belongs to. Returns `null` if
  /// the index is out of range.
  QueueZone? zoneOf(int flatIndex) {
    if (flatIndex < 0 || flatIndex >= length) return null;
    if (current == null) {
      // No current track — collapse into [...history, ...playNext, ...upcoming].
      if (flatIndex < history.length) return QueueZone.history;
      if (flatIndex < history.length + playNext.length) return QueueZone.playNext;
      return QueueZone.upcoming;
    }
    final currentIdx = history.length;
    if (flatIndex < currentIdx) return QueueZone.history;
    if (flatIndex == currentIdx) return QueueZone.current;
    if (flatIndex < currentIdx + 1 + playNext.length) return QueueZone.playNext;
    return QueueZone.upcoming;
  }
}

/// Riverpod [Notifier] owning the three-zone queue.
///
/// All mutations replace [state] with a new [QueueSnapshot]; the flat
/// projection is the contract `PlaybackService` diffs against to decide
/// whether to call `just_audio`'s `setAudioSources` (slice 1) or
/// `insertAudioSource` / `moveAudioSource` / `removeAudioSourceAt`
/// (slice 5's optimization).
///
/// No codegen — slice 1 stays on the hand-written `Notifier` +
/// `NotifierProvider.new` form. Riverpod 3 moved `StateNotifier` to
/// `legacy.dart`; we avoid that deprecation by using the modern base.
class QueueService extends Notifier<QueueSnapshot> {
  @override
  QueueSnapshot build() => const QueueSnapshot.empty();

  /// Replaces the queue with [tracks], starting at [startIndex].
  /// Entries before [startIndex] are discarded (they are not fed into
  /// [QueueZone.history]); history accumulates naturally as the user
  /// calls [advance]. A typical caller: `TracksScreen` tap-to-play.
  void loadContext(List<Track> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty) {
      state = const QueueSnapshot.empty();
      return;
    }
    final clamped = startIndex.clamp(0, tracks.length - 1);
    state = QueueSnapshot(
      current: tracks[clamped],
      upcoming: List<Track>.unmodifiable(tracks.sublist(clamped + 1)),
    );
  }

  /// Inserts [track] at the head of [QueueZone.playNext] — "play this
  /// next", above anything the context had already queued.
  void playNext(Track track) {
    state = QueueSnapshot(
      history: state.history,
      current: state.current,
      playNext: <Track>[track, ...state.playNext],
      upcoming: state.upcoming,
    );
  }

  /// Appends [track] to the tail of [QueueZone.upcoming]. The plan's
  /// name keeps the UX distinction clear: "Add to upcoming" never
  /// displaces a PlayNext entry.
  void addToUpcoming(Track track) {
    state = QueueSnapshot(
      history: state.history,
      current: state.current,
      playNext: state.playNext,
      upcoming: <Track>[...state.upcoming, track],
    );
  }

  /// Empties [QueueZone.playNext] without touching the other zones.
  void clearPlayNext() {
    if (state.playNext.isEmpty) return;
    state = QueueSnapshot(
      history: state.history,
      current: state.current,
      playNext: const <Track>[],
      upcoming: state.upcoming,
    );
  }

  /// Pushes [QueueZone.current] onto the tail of [QueueZone.history] and
  /// promotes the next playable track:
  ///
  /// - If [QueueZone.playNext] is non-empty, its head becomes [current].
  /// - Otherwise, if [QueueZone.upcoming] is non-empty, its head becomes
  ///   [current].
  /// - Otherwise [current] becomes `null` and the queue is drained.
  ///
  /// `PlaybackService` wires this to `currentIndexStream` moving
  /// forward past [currentIndex].
  void advance() {
    if (state.current == null) return;
    final newHistory = <Track>[...state.history, state.current!];
    if (state.playNext.isNotEmpty) {
      state = QueueSnapshot(
        history: newHistory,
        current: state.playNext.first,
        playNext: state.playNext.sublist(1),
        upcoming: state.upcoming,
      );
      return;
    }
    if (state.upcoming.isNotEmpty) {
      state = QueueSnapshot(
        history: newHistory,
        current: state.upcoming.first,
        playNext: state.playNext,
        upcoming: state.upcoming.sublist(1),
      );
      return;
    }
    state = QueueSnapshot(history: newHistory);
  }

  /// Inverse of [advance]: pulls the last [QueueZone.history] entry
  /// back to [QueueZone.current] and pushes the displaced current onto
  /// the head of [QueueZone.playNext]. No-ops when [QueueZone.history]
  /// is empty (there is nothing to promote).
  ///
  /// Wired to `PlaybackService.skipToPrevious` — since `just_audio`
  /// moves backward one source-list index per call, the queue must
  /// mirror that move or the flat projection falls out of sync with
  /// the player's source list.
  ///
  /// Invariant: if [QueueZone.current] is non-null both before and
  /// after, the [QueueSnapshot.flat] projection is identical
  /// (same tracks in the same order); only [QueueSnapshot.currentIndex]
  /// decreases by one. That lets `PlaybackService` skip rebuilding
  /// `AudioSource`s and merely seek.
  void retreat() {
    if (state.history.isEmpty) return;
    final newCurrent = state.history.last;
    final newHistory =
        state.history.sublist(0, state.history.length - 1);
    final newPlayNext = state.current == null
        ? state.playNext
        : <Track>[state.current!, ...state.playNext];
    state = QueueSnapshot(
      history: newHistory,
      current: newCurrent,
      playNext: newPlayNext,
      upcoming: state.upcoming,
    );
  }

  /// Reorders the entry at flat index [from] so it ends up at flat
  /// index [to] in the resulting snapshot. Zone ownership follows
  /// position: moving a [QueueZone.playNext] entry down into
  /// [QueueZone.upcoming] transfers it to upcoming, and vice versa.
  ///
  /// Convention: [to] is the **final resting index** of the moved
  /// entry. `move(1, 2)` swaps rows 1 and 2, `move(3, 0)` lifts row 3
  /// to the top. (Different from Flutter's `ReorderableListView` onReorder
  /// newIndex, which is pre-removal — callers wiring drag-and-drop
  /// must convert with `newIndex > oldIndex ? newIndex - 1 : newIndex`.)
  ///
  /// No-ops if:
  /// - either index is out of range;
  /// - `from == to`;
  /// - the move would displace [QueueZone.current] (moving into or out
  ///   of the current position). Slice 1's UI does not expose that
  ///   operation; swap-via-play is the right UX.
  void move(int from, int to) {
    final snap = state;
    final flatLen = snap.length;
    if (from < 0 || from >= flatLen) return;
    if (to < 0 || to >= flatLen) return;
    if (from == to) return;
    if (snap.current != null &&
        (from == snap.currentIndex || to == snap.currentIndex)) {
      return;
    }

    final fromZone = snap.zoneOf(from);
    final fromLocal = _localIndex(from, fromZone!, snap);

    // Pop from source zone.
    final h = <Track>[...snap.history];
    final pn = <Track>[...snap.playNext];
    final up = <Track>[...snap.upcoming];
    final Track item;
    switch (fromZone) {
      case QueueZone.history:
        item = h.removeAt(fromLocal);
      case QueueZone.playNext:
        item = pn.removeAt(fromLocal);
      case QueueZone.upcoming:
        item = up.removeAt(fromLocal);
      case QueueZone.current:
        return; // filtered above
    }

    // `to` is the desired final flat index. In the post-pop list, that
    // same index is the correct insertion point (insert(idx, …) places
    // the item at `idx` and shifts prior occupants right). The current
    // anchor slides left by 1 iff the popped item came from history.
    final adjustedTo = to;
    final postPopCurrentIdx = snap.current == null
        ? -1
        : (fromZone == QueueZone.history
            ? snap.currentIndex - 1
            : snap.currentIndex);

    final QueueZone toZone;
    final int toLocal;
    if (snap.current == null) {
      // No current anchor — history + playNext + upcoming are contiguous.
      if (adjustedTo < h.length) {
        toZone = QueueZone.history;
        toLocal = adjustedTo;
      } else if (adjustedTo < h.length + pn.length) {
        toZone = QueueZone.playNext;
        toLocal = adjustedTo - h.length;
      } else {
        toZone = QueueZone.upcoming;
        toLocal = adjustedTo - h.length - pn.length;
      }
    } else if (adjustedTo < postPopCurrentIdx) {
      toZone = QueueZone.history;
      toLocal = adjustedTo;
    } else if (adjustedTo == postPopCurrentIdx) {
      return; // landing on current — disallowed
    } else if (adjustedTo < postPopCurrentIdx + 1 + pn.length) {
      toZone = QueueZone.playNext;
      toLocal = adjustedTo - postPopCurrentIdx - 1;
    } else {
      toZone = QueueZone.upcoming;
      toLocal = adjustedTo - postPopCurrentIdx - 1 - pn.length;
    }

    switch (toZone) {
      case QueueZone.history:
        h.insert(toLocal, item);
      case QueueZone.playNext:
        pn.insert(toLocal, item);
      case QueueZone.upcoming:
        up.insert(toLocal, item);
      case QueueZone.current:
        return;
    }

    state = QueueSnapshot(
      history: h,
      current: snap.current,
      playNext: pn,
      upcoming: up,
    );
  }

  /// Removes the entry at flat index [flatIndex]. No-ops on
  /// [QueueZone.current] (use `skipToNext` / `skipToPrevious` instead)
  /// and out-of-range indices.
  void removeAt(int flatIndex) {
    final snap = state;
    if (flatIndex < 0 || flatIndex >= snap.length) return;
    final zone = snap.zoneOf(flatIndex);
    switch (zone) {
      case QueueZone.history:
        final h = <Track>[...snap.history]..removeAt(flatIndex);
        state = QueueSnapshot(
          history: h,
          current: snap.current,
          playNext: snap.playNext,
          upcoming: snap.upcoming,
        );
      case QueueZone.playNext:
        final local = _localIndex(flatIndex, QueueZone.playNext, snap);
        final pn = <Track>[...snap.playNext]..removeAt(local);
        state = QueueSnapshot(
          history: snap.history,
          current: snap.current,
          playNext: pn,
          upcoming: snap.upcoming,
        );
      case QueueZone.upcoming:
        final local = _localIndex(flatIndex, QueueZone.upcoming, snap);
        final up = <Track>[...snap.upcoming]..removeAt(local);
        state = QueueSnapshot(
          history: snap.history,
          current: snap.current,
          playNext: snap.playNext,
          upcoming: up,
        );
      case QueueZone.current:
      case null:
        return;
    }
  }

  /// Maps an absolute flat index to its local index within the given zone.
  static int _localIndex(int flat, QueueZone zone, QueueSnapshot snap) {
    final currentIdx = snap.currentIndex;
    switch (zone) {
      case QueueZone.history:
        return flat;
      case QueueZone.current:
        return 0;
      case QueueZone.playNext:
        // When current is null, playNext starts right after history.
        if (snap.current == null) return flat - snap.history.length;
        return flat - currentIdx - 1;
      case QueueZone.upcoming:
        if (snap.current == null) {
          return flat - snap.history.length - snap.playNext.length;
        }
        return flat - currentIdx - 1 - snap.playNext.length;
    }
  }
}

/// Riverpod 3 `NotifierProvider.new` wiring. Riverpod's 3.0 migration
/// moved `StateNotifierProvider` to `legacy.dart`; this is the
/// officially recommended successor.
final queueProvider =
    NotifierProvider<QueueService, QueueSnapshot>(QueueService.new);
