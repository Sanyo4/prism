import 'dart:async';

import 'package:prism_core/core.dart';

import '../cast_transport.dart';
import '../net/media_server.dart';
import 'didl_lite.dart';
import 'dlna_device.dart';
import 'soap.dart';

/// Slice-9 DLNA transport. Wires:
/// - [MediaServer] (registered tracks served over LAN with `Range:`).
/// - [Soap] (SOAP / AVTransport client for SetAVTransportURI / Play
///   / Pause / Seek / Stop / SetNextAVTransportURI / GetTransportInfo
///   / GetPositionInfo).
/// - [DlnaDevice] (the destination — typically the STR-DN1080).
///
/// Polls the receiver at 1 Hz via `GetTransportInfo` +
/// `GetPositionInfo` to drive the [TransportEvent] stream. When
/// the next URI takes over (queue auto-advance), emits
/// [TransportEnded] so the queue layer advances.
///
/// **`SetNextAVTransportURI` fallback:** if the receiver responds
/// `501 Action Not Supported` (slice-9 §10 risk 8), this transport
/// flips into hard-next mode — `setNext(t)` becomes a no-op and
/// the queue layer issues a fresh `SetAVTransportURI` + `Play` on
/// `TransportEnded`.
class DlnaTransport implements CastTransport {
  DlnaTransport({
    required DlnaDevice device,
    required MediaServer mediaServer,
    Soap? soap,
    bool useStrictDlnaProfile = false,
    Duration pollInterval = const Duration(seconds: 1),
  })  : _device = device,
        _mediaServer = mediaServer,
        _soap = soap ?? Soap(),
        _useStrictDlnaProfile = useStrictDlnaProfile,
        _pollInterval = pollInterval;

  final DlnaDevice _device;
  final MediaServer _mediaServer;
  final Soap _soap;
  final bool _useStrictDlnaProfile;
  final Duration _pollInterval;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  Timer? _poll;
  Track? _currentTrack;
  Uri? _currentUri;
  Track? _nextTrack;
  Uri? _nextUri;
  bool _supportsSetNext = true;
  bool _disposed = false;
  String? _lastState;
  Duration _lastPosition = Duration.zero;
  Duration? _lastDuration;

  /// Last polled playhead. Surfaced for Track B's `PlaybackService`
  /// — its remaining-time estimate (the queue-handoff cadence)
  /// reads this rather than waiting for a fresh
  /// [TransportPlaying] event.
  Duration get lastPosition => _lastPosition;

  /// Last polled duration. `null` when the receiver reports
  /// `NOT_IMPLEMENTED` or hasn't yet returned a valid TrackDuration.
  Duration? get lastDuration => _lastDuration;

  /// Currently-playing track. `null` before the first `setTrack`
  /// or after `dispose`. Surfaces for symmetry with
  /// [ChromecastTransport.currentTrack].
  Track? get currentTrack => _currentTrack;

  /// Queued-next track. `null` when no next is queued.
  Track? get nextTrack => _nextTrack;

  /// `true` once the receiver returned `501 Action Not Supported`
  /// for `SetNextAVTransportURI` — caller must hard-advance via
  /// `setTrack` on `TransportEnded`.
  bool get hardNextFallback => !_supportsSetNext;

  @override
  String get id => 'dlna:${_device.uuid}';

  @override
  String get displayName =>
      _device.friendlyName.isNotEmpty ? _device.friendlyName : _device.modelName;

  @override
  bool get isLossless => true;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  Future<void> setTrack(Track t) async {
    _currentTrack = t;
    _mediaServer.register(t);
    final url = _mediaServer.urlForFlac(t);
    _currentUri = url;
    final didl = _useStrictDlnaProfile
        ? DidlLite.buildWithPnTag(track: t, url: url)
        : DidlLite.build(track: t, url: url);
    await _soap.callAction(_device, 'SetAVTransportURI', args: {
      'CurrentURI': url.toString(),
      'CurrentURIMetaData': didl,
    });
    _ensurePolling();
  }

  @override
  Future<void> setNext(Track? t) async {
    if (!_supportsSetNext) {
      // Hard-next fallback: caller must re-issue SetAVTransportURI on
      // TransportEnded. Track the queued track for that handoff.
      _nextTrack = t;
      _nextUri = t == null ? null : _mediaServer.urlForFlac(t);
      return;
    }
    Uri? uri;
    String didl = '';
    if (t != null) {
      _mediaServer.register(t);
      uri = _mediaServer.urlForFlac(t);
      didl = _useStrictDlnaProfile
          ? DidlLite.buildWithPnTag(track: t, url: uri)
          : DidlLite.build(track: t, url: uri);
    }
    _nextTrack = t;
    _nextUri = uri;
    try {
      await _soap.callAction(_device, 'SetNextAVTransportURI', args: {
        'NextURI': uri?.toString() ?? '',
        'NextURIMetaData': didl,
      });
    } on SoapException catch (e) {
      if (e.isActionNotSupported) {
        _supportsSetNext = false;
        // Caller polls TransportEnded and re-issues setTrack.
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    await _soap.callAction(_device, 'Play', args: {'Speed': '1'});
    _ensurePolling();
  }

  @override
  Future<void> pause() async {
    await _soap.callAction(_device, 'Pause');
  }

  @override
  Future<void> seek(Duration to) async {
    await _soap.callAction(_device, 'Seek', args: {
      'Unit': 'REL_TIME',
      'Target': DidlLite.formatRelTime(to),
    });
  }

  @override
  Future<void> stop() async {
    await _soap.callAction(_device, 'Stop');
    _stopPolling();
    if (!_events.isClosed) {
      _events.add(const TransportStopped());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopPolling();
    _soap.dispose();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  void _ensurePolling() {
    if (_poll != null || _disposed) return;
    _poll = Timer.periodic(_pollInterval, (_) => unawaited(_pollOnce()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    if (_disposed || _events.isClosed) return;
    try {
      final transport =
          await _soap.callAction(_device, 'GetTransportInfo');
      final state = transport['CurrentTransportState'] ?? 'STOPPED';
      final position =
          await _soap.callAction(_device, 'GetPositionInfo');
      final relTime =
          _parseRelTime(position['RelTime']) ?? Duration.zero;
      final duration = _parseRelTime(position['TrackDuration']);
      final trackUri = position['TrackURI'];
      _lastPosition = relTime;
      _lastDuration = duration;
      // Detect gapless handoff: TrackURI moved from currentUri to
      // nextUri. The receiver auto-advanced on the SetNext queue.
      final advancedToNext = _nextUri != null &&
          trackUri != null &&
          trackUri == _nextUri.toString() &&
          trackUri != _currentUri?.toString();
      if (advancedToNext) {
        _events.add(const TransportEnded());
        _currentTrack = _nextTrack;
        _currentUri = _nextUri;
        _nextTrack = null;
        _nextUri = null;
      }
      // Also detect natural end: state transitioned away from PLAYING
      // toward STOPPED with the position near the duration. The hard-
      // next fallback path uses this.
      final naturalEnd = (_lastState == 'PLAYING') &&
          state == 'STOPPED' &&
          duration != null &&
          duration.inMilliseconds > 0 &&
          relTime.inMilliseconds >=
              (duration.inMilliseconds - 1500);
      if (naturalEnd && !advancedToNext) {
        _events.add(const TransportEnded());
      }
      switch (state) {
        case 'PLAYING':
          _events.add(
            TransportPlaying(position: relTime, duration: duration),
          );
          break;
        case 'PAUSED_PLAYBACK':
          _events.add(TransportPaused(position: relTime));
          break;
        case 'STOPPED':
          // Ended/Stopped events emitted above as appropriate.
          break;
      }
      _lastState = state;
    } on Object catch (e, st) {
      _events.add(TransportError(error: e, stack: st));
    }
  }

  /// Parses an AVTransport `HH:MM:SS[.fff]` value. Returns `null`
  /// when the receiver reports `NOT_IMPLEMENTED` or sends an empty
  /// / malformed value (we propagate that distinction so the
  /// natural-end heuristic doesn't mistakenly treat
  /// `TrackDuration=NOT_IMPLEMENTED` as "duration is zero").
  static Duration? _parseRelTime(String? s) {
    if (s == null || s.isEmpty || s == 'NOT_IMPLEMENTED') {
      return null;
    }
    final parts = s.split(':');
    if (parts.length != 3) return null;
    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    // Seconds may include `.fff` — parse the integer + fractional
    // portions defensively.
    final secondsToken = parts[2];
    final dot = secondsToken.indexOf('.');
    final secondsInt =
        int.tryParse(dot < 0 ? secondsToken : secondsToken.substring(0, dot)) ??
            0;
    final millis = dot < 0
        ? 0
        : int.tryParse(
              secondsToken
                  .substring(dot + 1)
                  .padRight(3, '0')
                  .substring(0, 3),
            ) ??
            0;
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: secondsInt,
      milliseconds: millis,
    );
  }
}
