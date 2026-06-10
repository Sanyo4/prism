import 'package:dio/dio.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:test/test.dart';

void main() {
  group('LastfmClient', () {
    test('returns null when no api key configured (fail-soft)', () async {
      final adapter = _StubAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://ws.audioscrobbler.com/2.0/'))
        ..httpClientAdapter = adapter;
      final client = LastfmClient(apiKey: null, dio: dio);

      var calls = 0;
      adapter.handler = (RequestOptions ro) {
        calls++;
        return ResponseBody.fromString('{}', 200, headers: {});
      };

      expect(client.configured, isFalse);
      expect(await client.artistInfo('mbid'), isNull);
      expect(calls, 0, reason: 'no key → no network');
    });

    test('parses bio + top 5 tags from a real-shape response', () async {
      final adapter = _StubAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://ws.audioscrobbler.com/2.0/'))
        ..httpClientAdapter = adapter;
      final client = LastfmClient(apiKey: 'test-key', dio: dio);

      adapter.handler = (RequestOptions ro) {
        expect(ro.queryParameters['method'], 'artist.getinfo');
        expect(ro.queryParameters['mbid'], 'art-mbid');
        expect(ro.queryParameters['api_key'], 'test-key');
        expect(ro.queryParameters['format'], 'json');
        return ResponseBody.fromString(_artistGetinfoJson, 200, headers: {
          'content-type': ['application/json'],
        });
      };

      final info = await client.artistInfo('art-mbid');
      expect(info, isNotNull);
      expect(info!.name, 'Nirvana');
      expect(info.bio, contains('grunge'));
      expect(info.tags, hasLength(5));
      expect(info.tags.first, 'grunge');
    });

    test('returns null when upstream returns the {error: 10} envelope',
        () async {
      final adapter = _StubAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://ws.audioscrobbler.com/2.0/'))
        ..httpClientAdapter = adapter;
      final client = LastfmClient(apiKey: 'badkey', dio: dio);

      adapter.handler = (RequestOptions ro) {
        return ResponseBody.fromString(
          '{"error":10,"message":"Invalid API key"}',
          200,
          headers: {'content-type': ['application/json']},
        );
      };

      expect(await client.artistInfo('mbid'), isNull);
    });

    test('returns null on empty bio + empty tags', () async {
      final adapter = _StubAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://ws.audioscrobbler.com/2.0/'))
        ..httpClientAdapter = adapter;
      final client = LastfmClient(apiKey: 'k', dio: dio);

      adapter.handler = (RequestOptions ro) {
        return ResponseBody.fromString(
          '{"artist": {"name":"Empty","mbid":"x","bio":{"content":""},"tags":{"tag":[]}}}',
          200,
          headers: {'content-type': ['application/json']},
        );
      };

      // Successful parse, but no actual content to render → null avoids
      // a placeholder-only artist-detail blurb.
      expect(await client.artistInfo('x'), isNull);
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

const _artistGetinfoJson = '''
{
  "artist": {
    "name": "Nirvana",
    "mbid": "art-mbid",
    "bio": {
      "content": "Nirvana was an American grunge band formed in Aberdeen, Washington."
    },
    "tags": {
      "tag": [
        {"name": "grunge"},
        {"name": "rock"},
        {"name": "alternative"},
        {"name": "90s"},
        {"name": "seattle"},
        {"name": "extra-tag-should-be-dropped"}
      ]
    }
  }
}
''';
