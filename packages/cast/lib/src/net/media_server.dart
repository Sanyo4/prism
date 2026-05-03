import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:prism_core/core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'transcoder.dart';

/// Embedded HTTP server. DLNA receivers and Chromecast devices pull
/// the audio file from this server over LAN. Every request is a
/// `GET` for one of two routes:
///
/// - `/<sha1>.flac` — bare FLAC, served as-is from disk. The
///   STR-DN1080 issues several small `Range:` GETs for ID3 / FLAC
///   metadata probing before settling into a sequential read; the
///   handler streams via `File.openRead(start, end+1)` so no buffer
///   accumulates.
/// - `/aac/<sha1>.m4a` — AAC-transcoded path for Chromecast (which
///   doesn't reliably handle FLAC). The transcode runs lazily — on
///   first request the [Transcoder] writes the m4a to the cache
///   directory; subsequent requests stream that file.
///
/// Tracks must be `register`ed before the URL builders return
/// useful values; [DlnaTransport] and [ChromecastTransport] register
/// the current + next track pair around every `setTrack` /
/// `setNext` call.
class MediaServer {
  MediaServer({Transcoder? transcoder}) : _transcoder = transcoder;

  /// Optional FLAC→AAC transcoder for the `/aac/...` route. `null`
  /// disables the AAC route — appropriate for Linux, where
  /// Chromecast is excluded entirely. DLNA push only needs the FLAC
  /// route, which is always available.
  final Transcoder? _transcoder;

  HttpServer? _server;
  InternetAddress? _publicAddress;
  final Map<String, Track> _registered = {};

  /// Addr the URL builders embed in returned URIs. Set to the
  /// LAN-facing IP picked by `IpSelector.pickLanAddress()`. The
  /// HTTP server still binds to `0.0.0.0` so it is reachable via
  /// every interface; only the URLs handed to the receiver use the
  /// resolved LAN address.
  InternetAddress? get publicAddress => _publicAddress;

  /// `true` once [start] has bound the listening socket.
  bool get isRunning => _server != null;

  /// Bound port. Only meaningful after [start]; throws otherwise.
  int get port {
    final s = _server;
    if (s == null) throw StateError('MediaServer is not running');
    return s.port;
  }

  /// Binds the listening socket. [bindAddress] selects the OS bind
  /// (almost always `InternetAddress.anyIPv4`); [publicAddress] is
  /// the address embedded in URL builders (typically the LAN IPv4).
  /// On Android and Linux these differ — bind on `0.0.0.0`, publish
  /// the Wi-Fi IP.
  Future<void> start({
    required InternetAddress publicAddress,
    InternetAddress? bindAddress,
  }) async {
    if (_server != null) {
      throw StateError('MediaServer already running');
    }
    _publicAddress = publicAddress;
    final router = Router()
      ..get('/<sha1>.flac', _handleFlac)
      ..get('/aac/<sha1>.m4a', _handleAac);
    _server = await shelf_io.serve(
      router.call,
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
  }

  /// Releases the listening socket. Subsequent calls are no-ops.
  Future<void> stop() async {
    final s = _server;
    if (s == null) return;
    _server = null;
    await s.close(force: true);
  }

  /// Registers [t] so the URL builders + handlers can resolve its
  /// SHA1 → file path. The same track may be registered repeatedly
  /// without effect.
  void register(Track t) {
    _registered[_sha1ForTrack(t)] = t;
  }

  /// Drops a previously-registered track. Useful when the queue
  /// rotates and a track no longer needs to be reachable.
  void unregister(Track t) {
    _registered.remove(_sha1ForTrack(t));
  }

  /// Resolves the public URL the receiver dials to fetch [t]'s
  /// FLAC bytes. Throws when the server hasn't been started or
  /// [publicAddress] hasn't been set.
  Uri urlForFlac(Track t) {
    final ip = _requirePublicAddress();
    return Uri(
      scheme: 'http',
      host: ip.address,
      port: port,
      path: '/${_sha1ForTrack(t)}.flac',
    );
  }

  /// Resolves the public URL the Chromecast device dials to fetch
  /// [t]'s AAC-transcoded bytes. Throws when the server hasn't been
  /// started, no transcoder was supplied, or [publicAddress] hasn't
  /// been set.
  Uri urlForAac(Track t) {
    if (_transcoder == null) {
      throw StateError(
        'MediaServer was constructed without a Transcoder; '
        'urlForAac is unavailable.',
      );
    }
    final ip = _requirePublicAddress();
    return Uri(
      scheme: 'http',
      host: ip.address,
      port: port,
      path: '/aac/${_sha1ForTrack(t)}.m4a',
    );
  }

  /// Stable hash of [t]'s path. Slice 4 stores `audio_sha1` on the
  /// sidecar but slice-1's [Track] doesn't carry it; we hash the
  /// path string. The hash is used only as a routing key — any
  /// stable hash of an addressable identifier works. The path is
  /// not exposed on the wire (the URL is `<sha1>.flac`); this is
  /// deliberate per slice-9 §10 risk 10.
  static String _sha1ForTrack(Track t) {
    return sha1.convert(utf8.encode(t.path)).toString();
  }

  InternetAddress _requirePublicAddress() {
    final ip = _publicAddress;
    if (ip == null) {
      throw StateError(
        'MediaServer.publicAddress is null; call start(...) first',
      );
    }
    return ip;
  }

  Future<Response> _handleFlac(Request request, String sha1Param) async {
    final track = _registered[sha1Param];
    if (track == null) {
      return Response.notFound('unknown sha1: $sha1Param');
    }
    final file = File(track.path);
    if (!await file.exists()) {
      return Response.notFound('file not on disk: ${track.path}');
    }
    return _serveFile(request, file, contentType: 'audio/flac');
  }

  Future<Response> _handleAac(Request request, String sha1Param) async {
    final transcoder = _transcoder;
    if (transcoder == null) {
      return Response.notFound('AAC route disabled (no transcoder)');
    }
    final track = _registered[sha1Param];
    if (track == null) {
      return Response.notFound('unknown sha1: $sha1Param');
    }
    final source = File(track.path);
    if (!await source.exists()) {
      return Response.notFound('file not on disk: ${track.path}');
    }
    final File aac;
    try {
      aac = await transcoder.flacToAac(source, bitrate: 128000);
    } on Object catch (e) {
      return Response.internalServerError(body: 'transcode failed: $e');
    }
    return _serveFile(request, aac, contentType: 'audio/mp4');
  }

  /// Range-honoring file serve. Per slice-9 §4:
  /// - Always sets `Accept-Ranges: bytes`.
  /// - Parses `Range: bytes=<start>-<end>?` (single closed range),
  ///   `bytes=<start>-` (open-ended), or `bytes=-<n>` (suffix).
  /// - Returns 206 + `Content-Range: bytes <s>-<e>/<total>` on a
  ///   successful range, 200 + full body otherwise.
  /// - 416 + `Content-Range: bytes */<total>` on out-of-range.
  static Future<Response> _serveFile(
    Request request,
    File file, {
    required String contentType,
  }) async {
    final total = await file.length();
    final rangeHeader = request.headers['range'] ?? request.headers['Range'];

    final commonHeaders = <String, String>{
      'content-type': contentType,
      'accept-ranges': 'bytes',
    };

    if (rangeHeader == null || rangeHeader.isEmpty) {
      return Response.ok(
        file.openRead(),
        headers: {
          ...commonHeaders,
          'content-length': total.toString(),
        },
      );
    }

    final parsed = _ByteRange.parse(rangeHeader, total: total);
    if (parsed == null) {
      return Response(
        416,
        headers: {
          ...commonHeaders,
          'content-range': 'bytes */$total',
        },
        body: 'invalid Range header',
      );
    }
    final length = parsed.end - parsed.start + 1;
    return Response(
      206,
      body: file.openRead(parsed.start, parsed.end + 1),
      headers: {
        ...commonHeaders,
        'content-length': length.toString(),
        'content-range': 'bytes ${parsed.start}-${parsed.end}/$total',
      },
    );
  }
}

/// Half-open closed-end byte range parsed from `Range:` headers.
///
/// Visible to the test surface so the parser is unit-testable
/// without spinning a real HTTP server.
class _ByteRange {
  _ByteRange(this.start, this.end);

  final int start;
  final int end;

  /// Parses `bytes=<start>-<end>?` or `bytes=-<suffix>`. Returns
  /// `null` for invalid / multi-range / out-of-bounds inputs.
  static _ByteRange? parse(String header, {required int total}) {
    if (total <= 0) return null;
    final h = header.trim().toLowerCase();
    const prefix = 'bytes=';
    if (!h.startsWith(prefix)) return null;
    final spec = h.substring(prefix.length);
    if (spec.contains(',')) return null; // we reject multi-range
    final dash = spec.indexOf('-');
    if (dash < 0) return null;

    final startStr = spec.substring(0, dash);
    final endStr = spec.substring(dash + 1);

    if (startStr.isEmpty) {
      // Suffix form: bytes=-N → last N bytes.
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return null;
      final start = (total - n).clamp(0, total - 1);
      return _ByteRange(start, total - 1);
    }
    final start = int.tryParse(startStr);
    if (start == null || start < 0 || start >= total) return null;
    if (endStr.isEmpty) {
      return _ByteRange(start, total - 1);
    }
    final end = int.tryParse(endStr);
    if (end == null || end < start) return null;
    final clampedEnd = end >= total ? total - 1 : end;
    return _ByteRange(start, clampedEnd);
  }
}
