/// Cooperative cancellation flag read by [LibraryScanner] between files.
///
/// The scanner checks [isCancelled] once per filesystem entry; a late
/// call to [cancel] interrupts the next iteration, not the in-flight
/// tag read. That's intentional — `audio_metadata_reader` opens the file
/// synchronously, and forcibly killing it mid-read would leak a
/// `RandomAccessFile`. Net latency: one tag read worst-case (~ms).
///
/// Single-use: calling [cancel] twice is a no-op. There's no reset;
/// create a new token per scan.
class CancellationToken {
  bool _cancelled = false;

  /// `true` after [cancel] has been invoked at least once.
  bool get isCancelled => _cancelled;

  /// Signals cancellation. Idempotent — subsequent calls are no-ops.
  void cancel() {
    _cancelled = true;
  }
}
