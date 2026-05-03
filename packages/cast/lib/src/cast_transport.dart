import 'dart:async';

import 'package:prism_core/core.dart';

/// Slice-9 transport-event family.
///
/// Every concrete [CastTransport] emits these on its broadcast
/// `events` stream. `PlaybackService` (Track B) consumes the stream
/// to keep the queue + UI in lock-step with whichever transport is
/// active. Sealed so a future event type is a compile error wherever
/// a `switch` statement assumes the closed set.
sealed class TransportEvent {
  const TransportEvent();
}

/// Emitted when the transport is actively playing. [position] is the
/// current playhead; [duration] becomes non-null once the active
/// source's total length is known (some renderers report duration
/// only after a few hundred ms of buffering).
class TransportPlaying extends TransportEvent {
  const TransportPlaying({required this.position, this.duration});

  /// Playhead within the active track.
  final Duration position;

  /// Total duration of the active track. `null` until known.
  final Duration? duration;
}

/// Emitted when the transport pauses. [position] is the playhead at
/// the moment of pause; the UI freezes the scrubber here.
class TransportPaused extends TransportEvent {
  const TransportPaused({required this.position});

  /// Playhead at pause.
  final Duration position;
}

/// Emitted when the transport stops (user-initiated stop, queue
/// drained, or remote session torn down). [reason] is opaque for
/// slice 9 — Track B may surface a banner using its `runtimeType`.
class TransportStopped extends TransportEvent {
  const TransportStopped({this.reason});

  /// Optional cause; e.g. an `Exception` for an error-path stop, or a
  /// string sentinel for "user pressed stop".
  final Object? reason;
}

/// Emitted when the active track ends naturally. The queue layer
/// advances on this. For DLNA, the poll loop fires this when
/// `RelTime ~= TrackDuration` and the next URI took over.
class TransportEnded extends TransportEvent {
  const TransportEnded();
}

/// Emitted when the transport encounters a non-fatal error. The
/// transport may continue (receiver hiccups, recoverable Cast
/// session blips); fatal failures emit `TransportStopped(reason:)`.
class TransportError extends TransportEvent {
  const TransportError({required this.error, this.stack});

  /// Underlying error object — typically a `DioException`,
  /// `SocketException`, or one of slice 9's bespoke exception types.
  final Object error;

  /// Stack at the moment of error capture. Surfaces in verbose log
  /// mode; UI does not show this.
  final StackTrace? stack;
}

/// Slice-9 transport surface. Every output sink — local speaker,
/// DLNA receiver, Chromecast device — implements this exact shape.
/// `PlaybackService` (Track B) holds one `currentTransport` and
/// delegates `play / pause / seek / setTrack / setNext` calls
/// through it. Swapping transports is `setTransport(new)` on the
/// service — nothing on this surface changes.
///
/// **Lifecycle**
/// - Construct → call `setTrack` (idempotent across the same track)
///   and optionally `setNext`.
/// - `play` / `pause` / `seek` operate on the current active source.
/// - `dispose` releases the underlying handle (HTTP server, Cast
///   session, DLNA SOAP client). After `dispose`, behaviour of
///   further calls is undefined — `PlaybackService` must construct
///   a fresh transport.
abstract class CastTransport {
  /// Stable identifier. Format conventions:
  ///   - `'local'` for [LocalTransport] (slice-1 player passthrough).
  ///   - `'dlna:<uuid>'` for [DlnaTransport] (UUID from SSDP USN).
  ///   - `'cast:<deviceId>'` for [ChromecastTransport] (Cast SDK device).
  String get id;

  /// Human-readable label for the cast sheet ("STR-DN1080",
  /// "Living Room Speaker"). UI may decorate this with a "Lossy"
  /// badge based on [isLossless].
  String get displayName;

  /// `true` when the transport carries the original audio stream
  /// bit-perfect. `false` for [ChromecastTransport] (which transcodes
  /// to 128 kbps AAC) — Track B's UI surfaces a "Lossy" badge for
  /// such transports.
  bool get isLossless;

  /// Broadcast stream of transport-state changes. Late subscribers do
  /// not receive replays of past events. Track B's `transportProvider`
  /// listens and pumps events into the queue + UI layers.
  Stream<TransportEvent> get events;

  /// Loads [t] as the current source and prepares it for playback. On
  /// DLNA this is `SetAVTransportURI` + DIDL-Lite metadata; on Cast
  /// it is `loadMedia(MediaInfo)`; on Local it is `setAudioSources`
  /// with a single-element list.
  ///
  /// Implementations should be idempotent for the same [t] — calling
  /// `setTrack(t)` twice should not interrupt audible playback when
  /// the second call is a no-op.
  Future<void> setTrack(Track t);

  /// Queues [t] as the next source. Pass `null` to clear a previously-
  /// queued next.
  ///
  /// On DLNA this is `SetNextAVTransportURI` (which the §10 risk 8
  /// fallback degrades to a hard-next on `501 Action Not Supported`).
  /// On Cast this populates the queue's next slot. On Local this is
  /// `insertAudioSource(currentIndex + 1, ...)`.
  ///
  /// Track B's `PlaybackService` calls this when the remaining-time
  /// estimate drops below 5 s — the cadence is owned by playback,
  /// not by this surface.
  Future<void> setNext(Track? t);

  /// Resumes the active source from its current playhead.
  Future<void> play();

  /// Pauses the active source at its current playhead.
  Future<void> pause();

  /// Seeks the active source to [to]. Receivers may clamp to the
  /// known duration; transports must tolerate seeks past the end
  /// (typically by treating them as `TransportEnded`).
  Future<void> seek(Duration to);

  /// Stops the active source. After `stop`, `play` may resume from
  /// the start of the source (DLNA / Cast) or require a fresh
  /// `setTrack` call (Local).
  Future<void> stop();

  /// Tears down the underlying handle. Must be safe to call multiple
  /// times. After dispose, the [events] stream closes and further
  /// calls have undefined behaviour.
  Future<void> dispose();
}
