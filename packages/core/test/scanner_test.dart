import 'dart:io';

import 'package:prism_core/core.dart';
import 'package:test/test.dart';

/// Minimal ID3v2.4 tag with zero frames — `audio_metadata_reader` accepts
/// this as a valid MP3 and returns an [AudioMetadata] with all tag
/// fields null. Used as the "valid audio file" fixture.
///
/// Layout:
///   - bytes 0..2  : "ID3"
///   - byte  3     : major version (4)
///   - byte  4     : revision     (0)
///   - byte  5     : flags        (0)
///   - bytes 6..9  : syncsafe size (0 frames → 0x00 0x00 0x00 0x00)
const List<int> _minimalId3v2Tag = <int>[
  0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

/// Unreadable-audio fixture: valid audio extension, garbage bytes. The
/// package rejects it because `ID3v2Parser.canUserParser` sees "XXX"
/// (not "ID3"), FLAC/OGG/MP4/RIFF magics don't match either, and
/// `readMetadata` throws `NoMetadataParserException`.
const List<int> _unreadableBytes = <int>[
  0x58, 0x58, 0x58, 0x58, 0x58, 0x58, 0x58, 0x58, // "XXXXXXXX"
];

Future<Directory> _seedFixtureTree(Directory root) async {
  // valid MP3 (minimal ID3v2.4 tag)
  final valid = File('${root.path}${Platform.pathSeparator}good.mp3');
  await valid.writeAsBytes(_minimalId3v2Tag);
  // supported extension, garbage bytes → parser rejects it
  final broken = File('${root.path}${Platform.pathSeparator}broken.mp3');
  await broken.writeAsBytes(_unreadableBytes);
  // unsupported extension → ScanSkipped
  final readme = File('${root.path}${Platform.pathSeparator}notes.txt');
  await readme.writeAsString('not an audio file');
  return root;
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('prism_scanner_');
    await _seedFixtureTree(tempRoot);
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test(
      'emits one Discovered, one Failed, one Skipped, and one Done '
      'for a mixed fixture tree', () async {
    final scanner = LibraryScanner();
    final token = CancellationToken();
    final events = await scanner.scan(tempRoot, token: token).toList();

    final discovered = events.whereType<ScanDiscovered>().toList();
    final failed = events.whereType<ScanFailed>().toList();
    final skipped = events.whereType<ScanSkipped>().toList();
    final done = events.whereType<ScanDone>().toList();

    expect(discovered, hasLength(1));
    expect(failed, hasLength(1));
    expect(skipped, hasLength(1));
    expect(done, hasLength(1));
    expect(done.single.cancelled, isFalse);
    expect(done.single.count, equals(1));

    // Identity of the single discovered track is the good.mp3 fixture.
    expect(discovered.single.track.path, endsWith('good.mp3'));
    expect(discovered.single.track.mtimeMs, greaterThan(0));

    // Failed + skipped target the expected files.
    expect(failed.single.path, endsWith('broken.mp3'));
    expect(skipped.single.path, endsWith('notes.txt'));
  });

  test(
      'cancellation between files short-circuits with '
      'ScanDone(cancelled: true)', () async {
    final scanner = LibraryScanner();
    final token = CancellationToken();
    final events = <ScanEvent>[];

    // Cancel as soon as we see the first per-file event; the scanner
    // checks the token between files so the next iteration should
    // yield ScanDone instead of another per-file event.
    await for (final e in scanner.scan(tempRoot, token: token)) {
      events.add(e);
      if (e is! ScanDone) token.cancel();
      if (e is ScanDone) break;
    }

    final done = events.whereType<ScanDone>().toList();
    expect(done, hasLength(1));
    expect(done.single.cancelled, isTrue);
    // At most one pre-cancel per-file event was observed.
    final perFile = events.whereType<ScanEvent>().where(
          (e) => e is! ScanDone,
        );
    expect(perFile.length, lessThanOrEqualTo(1));
  });

  test('missing root emits a Failed then a Done(cancelled:false,count:0)',
      () async {
    final scanner = LibraryScanner();
    final token = CancellationToken();
    final fake = Directory(
      '${tempRoot.path}${Platform.pathSeparator}does-not-exist',
    );
    final events = await scanner.scan(fake, token: token).toList();

    expect(events.whereType<ScanFailed>(), hasLength(1));
    final done = events.whereType<ScanDone>().single;
    expect(done.cancelled, isFalse);
    expect(done.count, equals(0));
  });

  test('pre-cancelled token yields only ScanDone(cancelled: true)', () async {
    final scanner = LibraryScanner();
    final token = CancellationToken()..cancel();
    final events = await scanner.scan(tempRoot, token: token).toList();

    expect(events, hasLength(1));
    expect(events.single, isA<ScanDone>());
    expect((events.single as ScanDone).cancelled, isTrue);
  });
}
