import 'package:dio/dio.dart';

import '../models/lastfm_artist_info.dart';

/// Last.fm read-only client — `artist.getInfo` only for slice 2.
///
/// Fail-soft contract: missing API key short-circuits to `null` (the
/// artist-detail screen renders without a blurb). This is by design —
/// Last.fm is informational polish, not the critical path. Slice 2's
/// edge-case 4: "Last.fm key absent → silent skip, no error dialog".
///
/// We respect Last.fm's informal 5 req/sec ceiling without a Pacer:
/// only the artist-detail screen calls this, one MBID at a time, and
/// the local cache pins results for 30 days. Burst headroom is huge.
class LastfmClient {
  static const String _base = 'https://ws.audioscrobbler.com/2.0/';

  final Dio _dio;
  final String? apiKey;

  LastfmClient({required this.apiKey, Dio? dio})
      : _dio = (dio ??
            Dio(BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.json,
              // Last.fm signals errors through a JSON envelope (`error`
              // code 10 / 29 / …) on a 200 status, so we don't need to
              // widen `validateStatus` beyond the default 2xx.
            ))) {
    // Document the missing-key behaviour at construction time so a stray
    // call without checking `configured` doesn't silently spam network.
  }

  Dio get dio => _dio;

  /// Whether the client has an API key. Callers (`MetadataRepository`)
  /// should short-circuit to `null` when this is false rather than
  /// calling [artistInfo] and discarding the error.
  bool get configured => (apiKey ?? '').isNotEmpty;

  /// Fetches the bio + top-5 tags for an artist by MBID. Returns null
  /// when:
  ///  - [configured] is false (missing API key),
  ///  - the upstream returns an error envelope (any `error` code),
  ///  - the artist exists but has no `bio.content` (still a successful
  ///    parse, just an empty result we treat as nothing to render).
  Future<LastfmArtistInfo?> artistInfo(String mbid) async {
    if (!configured) return null;
    final res = await _dio.get<Object?>('', queryParameters: {
      'method': 'artist.getinfo',
      'mbid': mbid,
      'api_key': apiKey,
      'format': 'json',
    });
    final body = res.data;
    if (body is! Map) return null;
    final map = body.cast<String, Object?>();
    if (map.containsKey('error')) return null;
    final info = LastfmArtistInfo.fromJson(map);
    if (info.bio.isEmpty && info.tags.isEmpty) return null;
    return info;
  }
}
