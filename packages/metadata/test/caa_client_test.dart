import 'package:dio/dio.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:test/test.dart';

void main() {
  group('CaaClient', () {
    late _StubAdapter adapter;
    late CaaClient client;

    setUp(() {
      adapter = _StubAdapter();
      final dio = Dio(BaseOptions(
        baseUrl: 'https://coverartarchive.org',
        followRedirects: false,
        validateStatus: (s) =>
            s != null && (s == 200 || s == 307 || s == 404),
      ))
        ..httpClientAdapter = adapter;
      client = CaaClient(dio: dio);
    });

    test('frontUrl returns the canonical /release/{mbid}/front-500 on 307',
        () async {
      adapter.handler = (RequestOptions ro) {
        expect(ro.method, 'HEAD');
        expect(ro.path, '/release/rel-mbid/front-500');
        return ResponseBody.fromString('', 307, headers: {
          'location': ['https://archive.org/...'],
        });
      };

      final art = await client.frontUrl('rel-mbid');
      expect(art, isNotNull);
      // We return the CAA path, NOT the 307 target. Cached_network_image
      // follows the redirect at load time.
      expect(art!.url, 'https://coverartarchive.org/release/rel-mbid/front-500');
      expect(art.releaseMbid, 'rel-mbid');
    });

    test('frontUrl returns null on 404 (no art known)', () async {
      adapter.handler = (RequestOptions ro) =>
          ResponseBody.fromString('', 404, headers: {});
      expect(await client.frontUrl('no-art'), isNull);
    });

    test('frontUrl handles direct 200 (no-redirect mirror)', () async {
      adapter.handler = (RequestOptions ro) =>
          ResponseBody.fromString('', 200, headers: {});
      final art = await client.frontUrl('mbid-200');
      expect(art, isNotNull);
      expect(
        art!.url,
        'https://coverartarchive.org/release/mbid-200/front-500',
      );
    });
  });
}

class _StubAdapter implements HttpClientAdapter {
  ResponseBody Function(RequestOptions)? handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    final h = handler;
    if (h == null) {
      throw StateError('handler not set on _StubAdapter');
    }
    return h(options);
  }

  @override
  void close({bool force = false}) {}
}
