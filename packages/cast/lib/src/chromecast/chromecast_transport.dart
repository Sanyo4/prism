import 'dart:async';
import 'dart:io' show Platform;

import 'package:prism_core/core.dart';

import '../cast_transport.dart';
import '../net/media_server.dart';
import 'chromecast_device.dart';

/// `true` when this build links a Chromecast Flutter binding. Set
/// manually here based on the doc-refresh outcome — Track A landed
/// `flutter_chrome_cast: ^1.1.1`, the only currently maintained
/// pub.dev binding. Track B's UI gates the "Cast devices" section
/// of the cast-sheet on this flag plus `Platform.isAndroid`.
///
/// Even with this flag `true`, [ChromecastTransport]'s constructor
/// asserts `Platform.isAndroid` because the underlying Cast SDK
/// native library is Android-only.
const bool kHasChromecastSupport = true;

/// Slice-9 Chromecast transport.
///
/// **Android-only.** Constructing on Linux throws an assertion —
/// the Cast SDK's native binding fails at runtime on every other
/// platform, and the transport is gated upstream by Track B's UI.
///
/// Plays the AAC-transcoded path served by [MediaServer] at
/// `http://<lan-ip>:<port>/aac/<sha1>.m4a`. The transcode runs lazy
/// on the first range fetch; subsequent skips reuse the cached file.
///
/// **`isLossless = false`** because the AAC encode is not bit-exact
/// — Chromecast cannot reliably handle 24/96 FLAC, so the
/// `MediaServer.urlForAac(t)` route is mandatory. Track B's UI
/// surfaces a "Lossy" badge when this transport is active.
///
/// **Implementation note:** slice-9 §15 lands the Cast Flutter
/// binding (`flutter_chrome_cast`) but the actual `loadMedia` /
/// `play` / `pause` SDK calls live behind a TODO(slice-9-integration)
/// marker — Track B's mobile-side wiring imports the plugin and
/// binds the FFI when the cast sheet picks a device. The transport's
/// public surface (this class) keeps `setTrack`/`play`/etc. as
/// no-op shells that record state and emit local events; the SDK
/// integration is mechanical once Track B exposes the live session
/// handle. Linux desktop never reaches this code path because the
/// constructor's `assert(Platform.isAndroid)` blocks construction.
class ChromecastTransport implements CastTransport {
  ChromecastTransport({
    required ChromecastDevice device,
    required MediaServer mediaServer,
  })  : _device = device,
        _mediaServer = mediaServer {
    assert(
      Platform.isAndroid,
      'ChromecastTransport is Android-only — gate on Platform.isAndroid '
      'before constructing. Linux desktop has no Chromecast transport.',
    );
  }

  final ChromecastDevice _device;
  final MediaServer _mediaServer;
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  Track? _currentTrack;
  Uri? _currentUri;
  Track? _nextTrack;
  Uri? _nextUri;
  bool _disposed = false;

  @override
  String get id => 'cast:${_device.id}';

  @override
  String get displayName => _device.friendlyName;

  @override
  bool get isLossless => false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  /// The URL the Cast SDK should pass as `contentUrl` in
  /// `GoogleCastMediaInformation`. Computed via
  /// `MediaServer.urlForAac(t)`. Surfaces it for Track B's
  /// integration; nothing else in this package consumes it.
  Uri? get currentContentUrl => _currentUri;

  /// The queued-next AAC URL, or `null` when nothing is queued.
  Uri? get nextContentUrl => _nextUri;

  /// Active device handle — Track B reads this to start a Cast
  /// session via `GoogleCastSessionManager.instance.startSessionWithDevice`.
  ChromecastDevice get device => _device;

  @override
  Future<void> setTrack(Track t) async {
    _currentTrack = t;
    _mediaServer.register(t);
    _currentUri = _mediaServer.urlForAac(t);
    // TODO(slice-9-integration): once Track B exposes the live
    // GoogleCastRemoteMediaClient handle, call:
    //   client.loadMedia(GoogleCastMediaInformation(
    //     contentId: t.path,
    //     contentUrl: _currentUri,
    //     contentType: 'audio/mp4',
    //     streamType: CastMediaStreamType.buffered,
    //     metadata: GoogleCastMusicTrackMediaMetadata(
    //       title: t.title, artist: t.artist, albumName: t.album,
    //     ),
    //   ), autoPlay: true);
  }

  @override
  Future<void> setNext(Track? t) async {
    _nextTrack = t;
    if (t == null) {
      _nextUri = null;
      return;
    }
    _mediaServer.register(t);
    _nextUri = _mediaServer.urlForAac(t);
    // TODO(slice-9-integration): client.queueAppend or queueInsertItems.
  }

  @override
  Future<void> play() async {
    // TODO(slice-9-integration): client.play().
  }

  @override
  Future<void> pause() async {
    // TODO(slice-9-integration): client.pause().
    if (!_events.isClosed) {
      _events.add(const TransportPaused(position: Duration.zero));
    }
  }

  @override
  Future<void> seek(Duration to) async {
    // TODO(slice-9-integration): client.seek(to).
  }

  @override
  Future<void> stop() async {
    // TODO(slice-9-integration): client.stop().
    if (!_events.isClosed) {
      _events.add(const TransportStopped());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (!_events.isClosed) {
      await _events.close();
    }
    // TODO(slice-9-integration): GoogleCastSessionManager.instance.endSession().
  }

  /// Currently-loaded track. Surfaces for Track B's UI when it
  /// renders the now-playing strip from the active transport.
  Track? get currentTrack => _currentTrack;

  /// Next-queued track, or `null`. Surfaces for symmetry with
  /// [currentTrack].
  Track? get nextTrack => _nextTrack;
}
