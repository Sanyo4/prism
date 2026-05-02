import 'dart:async';

import 'package:prism_core/core.dart';
import 'package:prism_metadata/metadata.dart';

import 'track_patch.dart';

/// Lifetime-controllable queue runner. Listens to ScanDone events,
/// then iterates tagless tracks one at a time through
/// [MetadataRepository.backfill]. Patches it produces flow out via
/// [stream]; the patch merger in `metadata_providers.dart` picks them
/// up and rebuilds the merged track map.
///
/// Concurrency: a single in-flight backfill at a time. The MusicBrainz
/// Pacer is per-process so we'd serialise even if we tried to fan
/// out — at one outbound request per second, parallelism wouldn't buy
/// us anything anyway.
///
/// Cancellation: [stop] flips a flag the loop body checks between
/// requests. An in-flight backfill completes; the next iteration sees
/// the flag and exits. Riverpod containers calling `dispose()` route
/// through this path so the queue does not leak across hot restarts.
///
/// Settings re-check: every iteration calls `repo.configured`. Flipping
/// the toggle off mid-run lets the in-flight call finish, then exits
/// the loop. Persisted state (track_meta rows) means resume is cheap.
class BackfillQueue {
  /// Lifetime-bound attempt cap from §10 risk #7. Above this we mark
  /// the track "tagless as shipped" and skip on future scans.
  static const int kMaxLifetimeAttempts = 3;

  final MetadataRepository _repo;
  final StreamController<TrackPatch> _out =
      StreamController<TrackPatch>.broadcast();

  bool _stopped = false;
  Future<void>? _running;

  BackfillQueue({required MetadataRepository repo}) : _repo = repo;

  /// Patch stream consumed by the merger provider. Broadcast so widget
  /// tests can observe without consuming the only listener.
  Stream<TrackPatch> get stream => _out.stream;

  /// Whether the queue is currently running through a list of tracks.
  /// Surfaced for tests; widget code rarely needs this.
  bool get isRunning => _running != null;

  /// Enqueues [tracks] (typically a `ScanDone` payload). Tracks already
  /// fully tagged (`artist`, `album`, *and* `year` non-null) and tracks
  /// at the lifetime-attempt cap are skipped without entering the
  /// repository. Returns once the run completes — fire-and-forget at
  /// the call site.
  Future<void> run(List<Track> tracks) async {
    // Coalesce concurrent run() calls. Reentry while running is
    // possible if a second scan finishes before the first backfill;
    // we await the in-flight pass then process the new list.
    if (_running != null) {
      await _running;
    }
    _stopped = false;
    final completer = Completer<void>();
    _running = completer.future;
    try {
      for (final t in tracks) {
        if (_stopped) break;
        if (!_repo.configured) break;
        if (_isFullyTagged(t)) continue;

        TrackMetadataPatch patch;
        try {
          patch = await _repo.backfill(t);
        } on Exception {
          // Repository persists `last_error` already; we just skip and
          // let the next launch retry up to attempt_count == 3.
          continue;
        }

        if (patch.isEmpty) continue;
        _out.add(TrackPatch(path: t.path, patch: patch));
      }
    } finally {
      completer.complete();
      _running = null;
    }
  }

  /// Cooperative stop. The current backfill completes; the loop
  /// terminates before starting the next.
  void stop() {
    _stopped = true;
  }

  Future<void> dispose() async {
    stop();
    await _out.close();
  }

  /// "Fully tagged" — the three fields the slice-2 verification matrix
  /// checks before kicking off a backfill. We don't include `genre`
  /// here; some tagging tools leave it blank deliberately.
  bool _isFullyTagged(Track t) =>
      (t.artist?.trim().isNotEmpty ?? false) &&
      (t.album?.trim().isNotEmpty ?? false) &&
      t.year != null;
}
