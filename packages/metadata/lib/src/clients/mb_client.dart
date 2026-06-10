import 'package:dio/dio.dart';

import '../models/mb_artist.dart';
import '../models/mb_recording.dart';
import '../models/mb_release.dart';
import '../pacer.dart';

/// Read-only MusicBrainz client. Every outbound request goes through a
/// [Pacer] (1 req/sec by default) and carries a `User-Agent` header
/// identifying the app + a contact email — both are mandatory per
/// `/doc/MusicBrainz_API` (silent UA-based bans for anonymous traffic).
///
/// Why a thin wrapper rather than `dio.get` at every call site: the
/// Pacer + 503 → `Pacer503Exception` conversion + JSON-error coverage
/// must run on every request, and centralising it here is the only
/// place the BackfillQueue is allowed to touch MB. CAA + Last.fm have
/// their own clients with separate informal budgets.
///
/// Status semantics:
///  - 2xx → JSON parsed, models returned.
///  - 503 → throws [Pacer503Exception] for the Pacer to back-off + retry.
///  - other → throws [DioException] (BackfillQueue catches and persists
///    `last_error` on the `track_meta` row).
class MbClient {
  /// `User-Agent` per MB rate-limit guidance: `App/version ( contact )`.
  /// Built once in the ctor and pinned to BaseOptions.headers; we never
  /// pass `Options(headers: ...)` per-call because that loses the UA.
  static const String _baseUrl = 'https://musicbrainz.org/ws/2/';

  final Dio _dio;
  final Pacer pacer;

  /// Builds an MbClient with a Pacer-shared 1 req/sec budget.
  ///
  /// [contactEmail] is mandatory — empty / null is a programmer error.
  /// MusicBrainz refuses to identify an application that does not
  /// expose a contact, so we fail-fast in the ctor rather than at
  /// request time.
  ///
  /// [pacer] can be injected for tests; production callers share one
  /// global Pacer with the rest of the metadata layer.
  MbClient({
    required String userAgent,
    Pacer? pacer,
    Dio? dio,
  })  : assert(userAgent.contains('('),
            'User-Agent must include a contact in parens, e.g. '
            '"Prism/0.2.0 ( me@example.com )"'),
        pacer = pacer ?? Pacer(interval: const Duration(seconds: 1)),
        _dio = (dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                responseType: ResponseType.json,
                // Default would only allow 2xx; we additionally let 503
                // through so `_request` can convert it to a
                // Pacer503Exception. 4xx + other 5xx still bubble as
                // DioException — `lookupArtist` catches the 404 case
                // explicitly to satisfy "merged-MBID returns null".
                validateStatus: (s) =>
                    s != null && ((s >= 200 && s < 300) || s == 503),
                headers: {
                  'User-Agent': userAgent,
                  'Accept': 'application/json',
                },
              ),
            ));

  /// Visible to tests — the underlying Dio instance the constructor
  /// either built or accepted. Production callers must not touch this.
  Dio get dio => _dio;

  /// Searches `/recording` by title + artist. Returns recordings sorted
  /// by descending score. The repository drops anything below 80.
  ///
  /// We hand-build the Lucene-style query because letting `dio` URL-
  /// encode the raw user input lets a quote in the title break the
  /// query. The escape rule from `/doc/MusicBrainz_API/Search` is:
  ///   + - && || ! ( ) { } [ ] ^ " ~ * ? : \
  Future<List<MbRecording>> searchRecording({
    required String title,
    String? artist,
    int limit = 5,
  }) async {
    final terms = <String>['recording:"${_lucene(title)}"'];
    if (artist != null && artist.isNotEmpty) {
      terms.add('artist:"${_lucene(artist)}"');
    }
    final res = await _request<Map<String, Object?>>(
      path: 'recording',
      query: {
        'query': terms.join(' AND '),
        'limit': '$limit',
        'fmt': 'json',
      },
    );
    final list = res['recordings'];
    if (list is! List) return const [];
    return list
        .map(MbRecording.fromJson)
        .toList(growable: false);
  }

  /// Searches `/release` by album + (optional) artist. Used as a
  /// fallback when `/recording` has no high-score hit.
  Future<List<MbRelease>> searchRelease({
    required String album,
    String? artist,
    int limit = 5,
  }) async {
    final terms = <String>['release:"${_lucene(album)}"'];
    if (artist != null && artist.isNotEmpty) {
      terms.add('artist:"${_lucene(artist)}"');
    }
    final res = await _request<Map<String, Object?>>(
      path: 'release',
      query: {
        'query': terms.join(' AND '),
        'limit': '$limit',
        'fmt': 'json',
      },
    );
    final list = res['releases'];
    if (list is! List) return const [];
    return list.map(MbRelease.fromJson).toList(growable: false);
  }

  /// Lookup an artist by MBID with `inc=tags` so the artist-detail
  /// page can render top-5 tags alongside the Last.fm bio.
  ///
  /// Returns `null` on 404 — MB occasionally returns a recording-
  /// embedded artist MBID that has since been merged.
  Future<MbArtist?> lookupArtist(String mbid) async {
    try {
      final res = await _request<Map<String, Object?>>(
        path: 'artist/$mbid',
        query: {
          'inc': 'tags',
          'fmt': 'json',
        },
      );
      return MbArtist.fromJson(res);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Single ingress point that runs every MB request through the Pacer
  /// and converts 503 → [Pacer503Exception] so the Pacer can back-off.
  /// All other status codes pass straight to the caller.
  Future<T> _request<T extends Object>({
    required String path,
    required Map<String, dynamic> query,
  }) async {
    return pacer.run<T>(() async {
      final res = await _dio.get<Object?>(path, queryParameters: query);
      if (res.statusCode == 503) {
        // MB sometimes ships a Retry-After in seconds; respect it.
        final ra = res.headers.value('retry-after');
        final secs = int.tryParse(ra ?? '');
        throw Pacer503Exception(
          secs == null ? Duration.zero : Duration(seconds: secs),
        );
      }
      final body = res.data;
      if (body is! T) {
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          type: DioExceptionType.badResponse,
          message: 'unexpected response shape: ${body.runtimeType}',
        );
      }
      return body;
    });
  }

  /// Lucene escape per MB search docs. Backslash-escapes the reserved
  /// set so user titles like `Don't Look Back ("Live")` don't crash
  /// the parser on the upstream side.
  String _lucene(String s) {
    final out = StringBuffer();
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      if ('+-&|!(){}[]^"~*?:\\'.contains(ch)) {
        out.write('\\');
      }
      out.write(ch);
    }
    return out.toString();
  }
}
