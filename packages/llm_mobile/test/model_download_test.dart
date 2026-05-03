import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:prism_llm_mobile/llm_mobile.dart';
import 'package:test/test.dart';

void main() {
  // Body shipped in 4 chunks. Total length 64 bytes; SHA256
  // computed at startup so the spec we hand the downloader
  // matches what the stub returns.
  final body = Uint8List.fromList(
    List<int>.generate(64, (i) => i & 0xFF),
  );
  final goodSha = sha256.convert(body).toString();

  CactusModelSpec specWithSha(String shaHex, {int sizeBytes = 64}) {
    return CactusModelSpec(
      weightsUrl: Uri.parse('https://example.test/weights.zip'),
      revision: 'rev1',
      fileName: 'weights.zip',
      sizeBytes: sizeBytes,
      sha256Hex: shaHex,
    );
  }

  Future<Directory> Function() rootProvider(Directory tmp) =>
      () async => tmp;

  group('ModelDownloader.start', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('llm_mobile_test_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on Object {
        // Best-effort
      }
    });

    test('refuses to start when the SHA pin is empty', () async {
      final spec = specWithSha('');
      final adapter = _StubAdapter()..bodyChunks = [body];
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(events, isNotEmpty);
      expect(events.last.phase, DownloadPhase.failed);
      expect(events.last.errorMessage, contains('pin missing'));
      expect(adapter.calls, isEmpty); // never hit the wire
    });

    test('happy path: 4-chunk body → SHA256 match → done + final file '
        'on disk', () async {
      final spec = specWithSha(goodSha);
      final adapter = _StubAdapter()
        ..bodyChunks = _splitToChunks(body, 4)
        ..responseStatus = 200;
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      // Phases observed: connecting → (downloading)* → verifying → done.
      final phases = events.map((e) => e.phase).toList();
      expect(phases.first, DownloadPhase.connecting);
      expect(phases, contains(DownloadPhase.verifying));
      expect(phases.last, DownloadPhase.done);

      final finalFile = await paths.finalFile();
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), spec.sizeBytes);

      // Second call short-circuits via isComplete().
      final more = <DownloadProgress>[];
      final sub2 = dl.progress.listen(more.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub2.cancel();
      // Final phase still done; no new connecting event because we
      // bailed at isComplete().
      expect(more.last.phase, DownloadPhase.done);
    });

    test('SHA256 mismatch deletes the partial and surfaces failed', () async {
      // Pin a bogus SHA so the post-download verification fails.
      final spec = specWithSha('a' * 64);
      final adapter = _StubAdapter()
        ..bodyChunks = [body]
        ..responseStatus = 200;
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(events.last.phase, DownloadPhase.failed);
      expect(events.last.errorMessage, contains('Checksum mismatch'));
      // .partial deleted; final never created.
      expect(await (await paths.partialFile()).exists(), isFalse);
      expect(await (await paths.finalFile()).exists(), isFalse);
    });

    test('pause() cancels the in-flight token and surfaces paused', () async {
      final spec = specWithSha(goodSha);
      // Adapter pauses BETWEEN chunks (not before the first byte) so
      // dio's stream-side cancel token has a `await` point to fire
      // on. We pause at the per-chunk-delay boundary which is long
      // enough that pause() reliably wins the race.
      final adapter = _StubAdapter()
        ..bodyChunks = _splitToChunks(body, 8)
        ..chunkDelay = const Duration(seconds: 1)
        ..responseStatus = 200;
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      // Pause well within the first chunk window. The 1-second
      // chunkDelay gives a 100ms cancel a full 900ms of slack.
      Future<void>.delayed(const Duration(milliseconds: 100), dl.pause);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();

      expect(events.last.phase, DownloadPhase.paused);
    });

    test('resume sends a Range header derived from the existing '
        '.partial size', () async {
      final spec = specWithSha(goodSha);
      // Pre-create a partial of the first 16 bytes, then run the
      // downloader. The stub records the inbound Range header.
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final partial = await paths.partialFile();
      await partial.writeAsBytes(body.sublist(0, 16));
      // Tail body the stub serves — the remaining 48 bytes.
      final adapter = _StubAdapter()
        ..bodyChunks = [body.sublist(16)]
        ..responseStatus = 206;
      final dio = Dio()..httpClientAdapter = adapter;
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(adapter.calls, hasLength(1));
      expect(
        adapter.calls.first.headers['range'] ??
            adapter.calls.first.headers['Range'],
        'bytes=16-',
      );
      // After resume, the appended file must match the full SHA.
      final finalFile = await paths.finalFile();
      expect(await finalFile.exists(), isTrue);
      expect(await finalFile.length(), spec.sizeBytes);
    });

    test('isComplete() returns false before download, true after', () async {
      final spec = specWithSha(goodSha);
      final adapter = _StubAdapter()
        ..bodyChunks = [body]
        ..responseStatus = 200;
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      expect(await dl.isComplete(), isFalse);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await dl.isComplete(), isTrue);
    });

    test('isComplete() rejects a corrupted final file', () async {
      final spec = specWithSha(goodSha);
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      // Plant a final file with the right name but wrong contents.
      final finalFile = await paths.finalFile();
      await finalFile.writeAsBytes(Uint8List.fromList(List.filled(64, 1)));
      final dio = Dio()..httpClientAdapter = _StubAdapter();
      final dl = ModelDownloader(dio, spec, paths);
      expect(await dl.isComplete(), isFalse);
    });

    test('non-cancel DioException surfaces failed', () async {
      final spec = specWithSha(goodSha);
      final adapter = _StubAdapter()..responseStatus = 500;
      final dio = Dio()..httpClientAdapter = adapter;
      final paths = ModelPaths(rootDirProvider: rootProvider(tmp), spec: spec);
      final dl = ModelDownloader(dio, spec, paths);

      final events = <DownloadProgress>[];
      final sub = dl.progress.listen(events.add);
      await dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(events.last.phase, DownloadPhase.failed);
    });
  });
}

/// Split [bytes] into [n] roughly-equal chunks for the stub to
/// stream. Empty trailing chunks are not produced.
List<Uint8List> _splitToChunks(Uint8List bytes, int n) {
  if (n <= 1) return [bytes];
  final size = (bytes.length / n).ceil();
  final out = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += size) {
    out.add(Uint8List.sublistView(
      bytes,
      i,
      i + size > bytes.length ? bytes.length : i + size,
    ));
  }
  return out;
}

/// Hand-rolled dio adapter — mirrors slice-2's `_StubAdapter`. Records
/// every inbound request and serves a configurable byte stream.
class _StubAdapter implements HttpClientAdapter {
  /// Each `Uint8List` is one streamed chunk delivered to dio in
  /// order. dio assembles the file from these.
  List<Uint8List> bodyChunks = const [];

  /// Optional delay between chunks — used for pause-mid-stream tests.
  Duration chunkDelay = Duration.zero;

  /// HTTP status code returned. 200 for full responses, 206 for
  /// partial (resume) responses, 500 to simulate a server error.
  int responseStatus = 200;

  /// Records every `RequestOptions` received. Tests assert against
  /// `.first.headers['Range']` for resume tests.
  final List<RequestOptions> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    calls.add(options);

    if (responseStatus >= 400) {
      // Bypass dio's stream → bytes plumbing by returning a body
      // with the error code; dio will raise badResponse on its own.
      return ResponseBody.fromString(
        'error',
        responseStatus,
        headers: const {
          'content-type': ['text/plain'],
        },
      );
    }

    final controller = StreamController<Uint8List>();
    unawaited(() async {
      try {
        for (final chunk in bodyChunks) {
          if (chunkDelay > Duration.zero) {
            await Future<void>.delayed(chunkDelay);
          }
          if (controller.isClosed) return;
          controller.add(chunk);
        }
        await controller.close();
      } on Object catch (e, st) {
        controller.addError(e, st);
        await controller.close();
      }
    }());

    final totalLen = bodyChunks.fold<int>(0, (a, b) => a + b.length);
    return ResponseBody(
      controller.stream,
      responseStatus,
      headers: {
        'content-type': const ['application/octet-stream'],
        'content-length': [totalLen.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
