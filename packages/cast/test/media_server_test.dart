import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';

/// Slice-9 §8 step 4 contract: full GET, mid-range, suffix-range,
/// 404 on unknown sha1, AAC route delegation. These cover §10
/// risk 5 (multiple small Range:s during STR-DN1080's metadata
/// probe) by sequencing distinct ranges over the same connection.
void main() {
  late Directory tmp;
  late File testFlac;
  late MediaServer server;
  late Track track;
  late HttpClient client;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('media_server_test_');
    testFlac = File('${tmp.path}/test.flac');
    // 4 KiB of deterministic bytes so we can assert exact content
    // ranges without ambiguity.
    final bytes = Uint8List.fromList(
      List<int>.generate(4096, (i) => i & 0xFF),
    );
    await testFlac.writeAsBytes(bytes);
    track = Track(
      path: testFlac.path,
      mtimeMs: DateTime.now().millisecondsSinceEpoch,
      title: 'Test Track',
      duration: const Duration(seconds: 30),
    );
    server = MediaServer(transcoder: _StubTranscoder(testFlac));
    await server.start(
      publicAddress: InternetAddress('127.0.0.1'),
      bindAddress: InternetAddress.loopbackIPv4,
    );
    server.register(track);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    try {
      await tmp.delete(recursive: true);
    } on Object {
      // Best-effort.
    }
  });

  group('MediaServer FLAC route', () {
    test('full GET returns 200 with the entire file body', () async {
      final url = server.urlForFlac(track);
      final body = await _get(client, url);
      expect(body.statusCode, 200);
      expect(body.contentLength, 4096);
      expect(body.bytes, hasLength(4096));
      expect(body.bytes[0], 0x00);
      expect(body.bytes[255], 0xFF);
      expect(body.headers['accept-ranges']?.first, 'bytes');
      expect(body.headers['content-type']?.first, contains('audio/flac'));
    });

    test('mid-range GET returns 206 with the requested slice', () async {
      final url = server.urlForFlac(track);
      final body = await _get(client, url, range: 'bytes=512-1023');
      expect(body.statusCode, 206);
      expect(body.contentLength, 512);
      expect(body.bytes, hasLength(512));
      expect(body.bytes[0], 0x00); // 512 % 256 = 0
      expect(body.bytes[1], 0x01);
      expect(body.headers['content-range']?.first, 'bytes 512-1023/4096');
    });

    test('suffix-range GET (bytes=-N) returns 206 with the last N '
        'bytes', () async {
      final url = server.urlForFlac(track);
      final body = await _get(client, url, range: 'bytes=-1024');
      expect(body.statusCode, 206);
      expect(body.contentLength, 1024);
      expect(body.bytes, hasLength(1024));
      // Last 1024 bytes start at offset 3072. 3072 % 256 = 0.
      expect(body.bytes[0], 0x00);
      expect(body.bytes[1], 0x01);
      expect(body.headers['content-range']?.first, 'bytes 3072-4095/4096');
    });

    test('open-ended range (bytes=N-) returns 206 with the tail', () async {
      final url = server.urlForFlac(track);
      final body = await _get(client, url, range: 'bytes=4000-');
      expect(body.statusCode, 206);
      expect(body.bytes, hasLength(96));
      expect(body.headers['content-range']?.first, 'bytes 4000-4095/4096');
    });

    test('404 on unknown sha1', () async {
      final url = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/${'a' * 40}.flac',
      );
      final body = await _get(client, url);
      expect(body.statusCode, 404);
    });

    test('multiple sequential ranges return independent slices', () async {
      // Sony STR-DN1080 issues several small range probes before
      // settling. Verifying each request stands on its own catches
      // any accidental request-state leak through the handler.
      final url = server.urlForFlac(track);
      final r1 = await _get(client, url, range: 'bytes=0-3');
      expect(r1.statusCode, 206);
      expect(r1.bytes, [0x00, 0x01, 0x02, 0x03]);
      final r2 = await _get(client, url, range: 'bytes=2000-2003');
      expect(r2.statusCode, 206);
      expect(r2.bytes, [
        2000 & 0xFF,
        2001 & 0xFF,
        2002 & 0xFF,
        2003 & 0xFF,
      ]);
      final r3 = await _get(client, url, range: 'bytes=-4');
      expect(r3.statusCode, 206);
      expect(r3.bytes, hasLength(4));
    });
  });

  group('MediaServer AAC route', () {
    test('GET /aac/<sha1>.m4a streams the transcoder output', () async {
      final url = server.urlForAac(track);
      final body = await _get(client, url);
      expect(body.statusCode, 200);
      // _StubTranscoder echoes the FLAC bytes; we only care that
      // the route reached the transcoder and streamed data.
      expect(body.bytes, hasLength(4096));
      expect(body.headers['content-type']?.first, contains('audio/mp4'));
    });

    test('AAC route returns 404 on unknown sha1', () async {
      final url = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: server.port,
        path: '/aac/${'b' * 40}.m4a',
      );
      final body = await _get(client, url);
      expect(body.statusCode, 404);
    });
  });

  group('MediaServer URL builders', () {
    test('urlForFlac embeds the publicAddress + bound port', () {
      final url = server.urlForFlac(track);
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, server.port);
      expect(url.path, endsWith('.flac'));
    });

    test('urlForAac embeds /aac/ + .m4a', () {
      final url = server.urlForAac(track);
      expect(url.path, startsWith('/aac/'));
      expect(url.path, endsWith('.m4a'));
    });

    test('urlForFlac throws when MediaServer was never started', () async {
      final unstarted = MediaServer();
      expect(() => unstarted.urlForFlac(track), throwsStateError);
    });

    test('urlForAac throws when no transcoder is supplied', () async {
      final no = MediaServer();
      await no.start(
        publicAddress: InternetAddress('127.0.0.1'),
        bindAddress: InternetAddress.loopbackIPv4,
      );
      no.register(track);
      expect(() => no.urlForAac(track), throwsStateError);
      await no.stop();
    });
  });
}

/// Minimal HTTP GET helper.
class _Resp {
  _Resp(this.statusCode, this.bytes, this.headers);
  final int statusCode;
  final List<int> bytes;
  final Map<String, List<String>> headers;
  int get contentLength => bytes.length;
}

Future<_Resp> _get(HttpClient client, Uri url, {String? range}) async {
  final req = await client.getUrl(url);
  if (range != null) {
    req.headers.set('Range', range);
  }
  final res = await req.close();
  final out = <int>[];
  await res.forEach(out.addAll);
  final headerMap = <String, List<String>>{};
  res.headers.forEach((name, values) {
    headerMap[name.toLowerCase()] = values;
  });
  return _Resp(res.statusCode, out, headerMap);
}

/// Echo-style transcoder. Reads the source file and "transcodes" it
/// to a same-bytes copy under the cache directory. Lets us exercise
/// the AAC route without needing real ffmpeg.
class _StubTranscoder implements Transcoder {
  _StubTranscoder(this._source);
  final File _source;

  @override
  Future<File> flacToAac(File source, {required int bitrate}) async {
    final cache = await Directory.systemTemp
        .createTemp('media_server_test_aac_');
    final out = File('${cache.path}/out.m4a');
    await out.writeAsBytes(await _source.readAsBytes());
    return out;
  }
}
