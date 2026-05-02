import 'package:dio/dio.dart';

import '../models/caa_art.dart';

/// Cover Art Archive client. CAA imposes no published rate limit and
/// requires no auth, so we don't share the MusicBrainz Pacer — bursting
/// is fine. We do still keep this to one method (`frontUrl`) so any
/// future CAA traffic flows through the same chokepoint.
///
/// Behavior:
///  - HEAD `/release/{mbid}/front-500` to verify a 307 / 200 exists.
///  - 404 → returns null, caller caches the miss for 365 d.
///  - other status → DioException; caller persists `last_error`.
///
/// Why HEAD instead of GET: we hand the URL to `cached_network_image`,
/// which will issue its own GET. Doing a GET here would pull bytes
/// twice and waste the user's data — especially on Android.
class CaaClient {
  static const String _base = 'https://coverartarchive.org';

  final Dio _dio;

  CaaClient({Dio? dio})
      : _dio = (dio ??
            Dio(
              BaseOptions(
                baseUrl: _base,
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
                // 307 must surface as a Response so we can stop following
                // redirects ourselves; the image URL itself is what we
                // return to the caller.
                followRedirects: false,
                validateStatus: (s) =>
                    s != null && (s == 200 || s == 307 || s == 404),
                headers: {
                  'Accept': 'image/*, application/json;q=0.5',
                },
              ),
            ));

  Dio get dio => _dio;

  /// Returns a [CaaArt] when CAA has art for [releaseMbid], or `null`
  /// when CAA returns 404. Any other failure (network, DNS, 5xx) throws.
  ///
  /// Implementation note: the URL we return is the *canonical* CAA
  /// path, not the 307 target — `cached_network_image` follows the
  /// redirect on first load and caches the image bytes keyed by
  /// [releaseMbid] (passed via `cacheKey`).
  Future<CaaArt?> frontUrl(String releaseMbid) async {
    final path = '/release/$releaseMbid/front-500';
    final res = await _dio.head<Object?>(path);
    if (res.statusCode == 404) return null;
    if (res.statusCode == 200 || res.statusCode == 307) {
      return CaaArt(url: '$_base$path', releaseMbid: releaseMbid);
    }
    // Should not happen given validateStatus above, but defensive:
    throw DioException(
      requestOptions: res.requestOptions,
      response: res,
      type: DioExceptionType.badResponse,
      message: 'unexpected CAA status: ${res.statusCode}',
    );
  }
}
