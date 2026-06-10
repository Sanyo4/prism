import 'dart:async';

/// Single-slot mutex that releases one token every [interval]. Used as
/// the only entry point to MusicBrainz so we never exceed the
/// 1 req/sec anonymous budget published in `/doc/MusicBrainz_API/Rate_Limiting`.
///
/// Why a global single-token Pacer rather than a token bucket:
/// MusicBrainz's enforcement is per-IP + per-User-Agent; bursts past
/// the average earn a silent ban. A FIFO queue of capacity 1 with a
/// fixed minimum spacing is the simplest shape that cannot accidentally
/// burst, and `mb_client_test.dart` asserts the floor at ≥ 1000 ms
/// between consecutive calls.
///
/// Why an `interval`-typed delay rather than a token bucket: the bucket
/// shape would require us to track a credit balance + refill clock; a
/// single timestamp ("when is the next call allowed?") expresses the
/// invariant in two lines and is trivially unit-testable.
///
/// 503 handling — MusicBrainz returns 503 when throttled across any of
/// (UA, source IP, global capacity). The caller wraps the network
/// request, throws [Pacer503Exception] on 503, and the Pacer doubles
/// the spacing up to [maxBackoff] then retries once. A second 503 in
/// the same `run()` bubbles to the caller — the BackfillQueue will
/// stop the run and persist the position so the next launch resumes.
///
/// Concurrency: a chain of `await`s on a single [Future] is the FIFO
/// queue. There is no `Lock` package import; one less dep, and the
/// behaviour matches Dart's microtask ordering exactly.
class Pacer {
  /// Minimum spacing between consecutive [run] calls. MusicBrainz
  /// publishes 1 req/sec; defaulting to anything less is a footgun, so
  /// the parameter is required.
  final Duration interval;

  /// Cap on the exponential back-off applied after a 503. 64 s gives
  /// roughly six doublings from a 1 s base, which mirrors how long
  /// MusicBrainz typically holds a soft block before recovering.
  final Duration maxBackoff;

  /// The [Future] every queued caller awaits before claiming the slot.
  /// Refreshed at the end of each [run] to point at the next allowed
  /// timestamp; `null` until the first call.
  Future<void> _next = Future<void>.value();

  Pacer({required this.interval, this.maxBackoff = const Duration(seconds: 64)})
      : assert(interval > Duration.zero, 'interval must be positive');

  /// Awaits the next slot, runs [fn], then schedules the slot release
  /// `interval` later (or `currentBackoff` later if [fn] threw a
  /// [Pacer503Exception]).
  ///
  /// First 503: doubles the spacing (clamped to [maxBackoff]) and
  /// retries the same [fn] once. Second 503: re-throws — the call
  /// site decides whether to abort the queue or persist + retry next
  /// launch.
  Future<T> run<T>(Future<T> Function() fn) async {
    // Stand in line: every call awaits the previous "release timestamp".
    // We capture a local handle and immediately publish a new completer
    // so concurrent callers serialize through us in arrival order.
    final myTurn = _next;
    final release = Completer<void>();
    _next = release.future;
    await myTurn;

    Duration delayAfter = interval;
    try {
      try {
        return await fn();
      } on Pacer503Exception catch (e) {
        // First 503 — back off, then retry exactly once. The retry runs
        // *inside* the same slot so we don't have to re-queue; the slot
        // release is just deferred.
        final backoff =
            e.retryAfter > Duration.zero ? e.retryAfter : interval * 2;
        delayAfter = _clamp(backoff, maxBackoff);
        await Future<void>.delayed(delayAfter);
        return await fn();
      }
    } finally {
      // Slot opens `delayAfter` after we finish; whoever is waiting on
      // `_next` resumes once the timer fires.
      Future<void>.delayed(delayAfter, release.complete);
    }
  }

  static Duration _clamp(Duration value, Duration cap) =>
      value > cap ? cap : value;
}

/// Thrown by an [MbClient] (or any other Pacer-gated caller) when the
/// upstream returns 503. Carries [retryAfter] derived from the
/// `Retry-After` header when present; falls back to `Duration.zero`
/// (caller doubles the Pacer interval).
class Pacer503Exception implements Exception {
  final Duration retryAfter;
  const Pacer503Exception([this.retryAfter = Duration.zero]);

  @override
  String toString() => 'Pacer503Exception(retryAfter: $retryAfter)';
}
