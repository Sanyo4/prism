import '../models/track.dart';

/// One event emitted by [LibraryScanner] for each filesystem entry it
/// considers during a scan, plus a terminal [ScanDone].
///
/// A `Stream<ScanEvent>` (rather than `Stream<Track>`) lets callers see
/// per-file failures without aborting the whole scan — the UI turns
/// [ScanFailed] into a Settings toast and [ScanDone] into a banner.
sealed class ScanEvent {
  const ScanEvent();
}

/// A file was opened and parsed successfully; [track] is ready to play.
final class ScanDiscovered extends ScanEvent {
  final Track track;
  const ScanDiscovered(this.track);

  @override
  String toString() => 'ScanDiscovered(${track.path})';
}

/// A filesystem entry was rejected before parsing — typically an
/// unsupported extension. [reason] is human-readable diagnostic text.
final class ScanSkipped extends ScanEvent {
  final String path;
  final String reason;
  const ScanSkipped(this.path, this.reason);

  @override
  String toString() => 'ScanSkipped($path, $reason)';
}

/// Parsing or stat()ing threw. [error] preserves the original cause so
/// slice 2's Settings panel can render a non-lossy failure list.
final class ScanFailed extends ScanEvent {
  final String path;
  final Object error;
  const ScanFailed(this.path, this.error);

  @override
  String toString() => 'ScanFailed($path, $error)';
}

/// Terminal event emitted exactly once. [cancelled] is `true` when the
/// scanner exited because [CancellationToken.isCancelled] flipped mid-walk;
/// [count] is the number of [ScanDiscovered] events emitted.
final class ScanDone extends ScanEvent {
  final bool cancelled;
  final int count;
  const ScanDone({required this.cancelled, required this.count});

  @override
  String toString() => 'ScanDone(cancelled: $cancelled, count: $count)';
}
