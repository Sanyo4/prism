import 'package:dio/dio.dart';
import 'package:prism_metadata/metadata.dart';
import 'package:test/test.dart';

void main() {
  group('MbClient (canned responses via Dio adapter)', () {
    late _StubAdapter adapter;
    late MbClient client;

    setUp(() {
      adapter = _StubAdapter();
      final dio = Dio(BaseOptions(
        baseUrl: 'https://musicbrainz.org/ws/2/',
        // Mirror MbClient's prod validateStatus exactly so this stub
        // fails the same way at the same boundary the real client does.
        validateStatus: (s) =>
            s != null && ((s >= 200 && s < 300) || s == 503),
        headers: {
          'User-Agent': 'PrismTest/0.0.0 ( test@example.com )',
          'Accept': 'application/json',
        },
      ))
        ..httpClientAdapter = adapter;
      client = MbClient(
        userAgent: 'PrismTest/0.0.0 ( test@example.com )',
        // Tight Pacer keeps the test ms-fast.
        pacer: Pacer(interval: const Duration(milliseconds: 5)),
        dio: dio,
      );
    });

    test('searchRecording parses a 2-hit response and preserves order', () async {
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, 'recording');
        expect(ro.queryParameters['fmt'], 'json');
        expect(ro.queryParameters['query'], contains('recording:"In Bloom"'));
        expect(ro.queryParameters['query'], contains('artist:"Nirvana"'));
        return ResponseBody.fromString(_recordingsJson, 200, headers: {
          'content-type': ['application/json'],
        });
      };

      final hits = await client.searchRecording(
        title: 'In Bloom',
        artist: 'Nirvana',
      );
      expect(hits, hasLength(2));
      expect(hits[0].title, 'In Bloom');
      expect(hits[0].mbid, 'rec-1');
      expect(hits[0].score, 100);
      expect(hits[0].artistName, 'Nirvana');
      expect(hits[0].artistMbid, 'art-nirvana');
      expect(hits[0].releases, isNotEmpty);
      expect(hits[0].releases.first.mbid, 'rel-nevermind');
      expect(hits[0].releases.first.year, 1991);
      expect(hits[0].releases.first.primaryType, 'Album');
      expect(hits[0].releases.first.status, 'Official');
      expect(hits[0].releases.first.trackNo, 2);
      expect(hits[0].releases.first.discNo, 1);
    });

    test('searchRelease parses release-only response', () async {
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, 'release');
        return ResponseBody.fromString(_releaseSearchJson, 200, headers: {
          'content-type': ['application/json'],
        });
      };

      final hits = await client.searchRelease(
        album: 'Nevermind',
        artist: 'Nirvana',
      );
      expect(hits, hasLength(1));
      expect(hits[0].mbid, 'rel-nevermind');
      expect(hits[0].title, 'Nevermind');
      expect(hits[0].year, 1991);
      expect(hits[0].artistName, 'Nirvana');
      expect(hits[0].score, 99);
    });

    test('lookupArtist returns null on 404', () async {
      adapter.handler = (RequestOptions ro) {
        expect(ro.path, 'artist/missing-id');
        return ResponseBody.fromString('{}', 404, headers: {
          'content-type': ['application/json'],
        });
      };

      final artist = await client.lookupArtist('missing-id');
      expect(artist, isNull);
    });

    test('503 surfaces as Pacer503Exception (caller-visible after retry exhaust)',
        () async {
      // Force two 503s — the Pacer retries once, the second 503 bubbles.
      var calls = 0;
      adapter.handler = (RequestOptions ro) {
        calls++;
        return ResponseBody.fromString('{}', 503, headers: {
          'content-type': ['application/json'],
          'retry-after': ['1'],
        });
      };

      await expectLater(
        client.searchRecording(title: 'whatever'),
        throwsA(isA<Pacer503Exception>()),
      );
      expect(calls, 2);
    });

    test('Lucene-reserved chars in title are escaped', () async {
      String? capturedQuery;
      adapter.handler = (RequestOptions ro) {
        capturedQuery = ro.queryParameters['query'] as String;
        return ResponseBody.fromString('{"recordings":[]}', 200, headers: {
          'content-type': ['application/json'],
        });
      };
      await client.searchRecording(title: 'Don\'t Look Back ("Live")');
      // Parens + double-quote inside the user title must be backslash-
      // escaped before they hit the wire; otherwise the upstream Lucene
      // parser breaks. Apostrophe is *not* reserved, so we don't escape it.
      expect(capturedQuery, contains(r'\(\"Live\"\)'));
    });
  });
}

/// Minimal Dio adapter — every request invokes `handler`. Callers
/// inspect the [RequestOptions] to assert path/query then return a
/// [ResponseBody].
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

// --- Canned upstream payloads -------------------------------------------

const _recordingsJson = '''
{
  "created": "2026-05-02T00:00:00.000Z",
  "count": 2,
  "offset": 0,
  "recordings": [
    {
      "id": "rec-1",
      "score": 100,
      "title": "In Bloom",
      "length": 254000,
      "artist-credit": [
        {
          "name": "Nirvana",
          "artist": { "id": "art-nirvana", "name": "Nirvana" }
        }
      ],
      "releases": [
        {
          "id": "rel-nevermind",
          "title": "Nevermind",
          "status": "Official",
          "date": "1991-09-24",
          "country": "US",
          "release-group": { "id": "rg-1", "primary-type": "Album" },
          "media": [
            {
              "position": 1,
              "track-count": 13,
              "track": [{ "number": "2", "title": "In Bloom" }]
            }
          ]
        }
      ]
    },
    {
      "id": "rec-2",
      "score": 90,
      "title": "In Bloom (Live)",
      "artist-credit": [{ "name": "Nirvana", "artist": { "id": "art-nirvana", "name": "Nirvana" } }],
      "releases": []
    }
  ]
}
''';

const _releaseSearchJson = '''
{
  "created": "2026-05-02T00:00:00.000Z",
  "count": 1,
  "offset": 0,
  "releases": [
    {
      "id": "rel-nevermind",
      "score": 99,
      "title": "Nevermind",
      "status": "Official",
      "date": "1991-09-24",
      "country": "US",
      "release-group": { "id": "rg-1", "primary-type": "Album" },
      "artist-credit": [
        { "name": "Nirvana", "artist": { "id": "art-nirvana", "name": "Nirvana" } }
      ]
    }
  ]
}
''';
