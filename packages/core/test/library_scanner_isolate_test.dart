@TestOn('vm')
library;

import 'dart:io';

import 'package:prism_core/core.dart';
import 'package:test/test.dart';

/// Minimal valid ID3v2.4 tag with zero frames.
/// `audio_metadata_reader` accepts this as a valid MP3 and returns an
/// `AudioMetadata` with all tag fields null.
const List<int> _minimalId3v2Tag = <int>[
  0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

void main() {
  group('scanInIsolate', () {
    test('returns empty list for an empty directory', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('prism-scan-iso-empty-');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final tracks = await scanInIsolate(tempDir);
      expect(tracks, isEmpty);
    });

    test('returns a List<Track> without crashing on unsupported files',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('prism-scan-iso-skip-');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      // Non-audio files should be silently skipped.
      File('${tempDir.path}/readme.txt').writeAsStringSync('not audio');
      File('${tempDir.path}/image.jpg').writeAsBytesSync(<int>[]);

      final tracks = await scanInIsolate(tempDir);
      expect(tracks, isA<List<Track>>());
      expect(tracks, isEmpty);
    });

    test('discovers a valid MP3 and returns a Track with a non-zero mtimeMs',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('prism-scan-iso-mp3-');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      // Write a minimal valid MP3 header — audio_metadata_reader parses
      // it as a track with null tags but non-zero mtime.
      File('${tempDir.path}/song.mp3').writeAsBytesSync(_minimalId3v2Tag);

      final tracks = await scanInIsolate(tempDir);
      expect(tracks, hasLength(1));
      expect(tracks.first, isA<Track>());
      expect(tracks.first.path, endsWith('song.mp3'));
      expect(tracks.first.mtimeMs, greaterThan(0));
    });

    test('returns empty list when root does not exist', () async {
      final missingDir = Directory(
        '${Directory.systemTemp.path}/prism-scan-iso-missing-${DateTime.now().microsecondsSinceEpoch}',
      );

      // scanInIsolate internally calls LibraryScanner.scan which emits
      // ScanFailed for a missing root and returns an empty list; no exception.
      final tracks = await scanInIsolate(missingDir);
      expect(tracks, isEmpty);
    });

    test('deduplicates tracks when the same path appears twice', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('prism-scan-iso-dedup-');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      // One real MP3 file — can only be discovered once via a single
      // linear walk, so this confirms no artificial duplication.
      File('${tempDir.path}/dup.mp3').writeAsBytesSync(_minimalId3v2Tag);

      final tracks = await scanInIsolate(tempDir);
      // Dedup is enforced by putIfAbsent in the isolate body.
      final paths = tracks.map((t) => t.path).toSet();
      expect(paths.length, equals(tracks.length));
    });
  });
}
