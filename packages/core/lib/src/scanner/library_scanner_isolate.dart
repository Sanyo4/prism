import 'dart:io';
import 'dart:isolate';

import '../models/track.dart';
import 'cancellation_token.dart';
import 'library_scanner.dart';
import 'scan_event.dart';

/// Slice-10b §D3 — runs `LibraryScanner.scan(root)` in a worker
/// isolate so the FS walk + tag parsing don't block the UI thread.
///
/// Collects all [ScanDiscovered] events into a `List<Track>` and
/// returns it. [ScanFailed] / [ScanSkipped] events are silently
/// dropped inside the isolate — callers that want per-file failure
/// reporting should use [LibraryScanner.scan] directly.
///
/// `Isolate.run` handles spawn / message-pass / teardown end-to-end;
/// the isolate exits as soon as the body future resolves.
///
/// Usage:
/// ```dart
/// final tracks = await scanInIsolate(Directory('/storage/Music'));
/// ```
Future<List<Track>> scanInIsolate(Directory root) {
  // Pass the path as a plain String — safer across SDK versions than
  // sending a Directory object across isolate message boundaries.
  final path = root.path;
  return Isolate.run<List<Track>>(() async {
    final scanner = LibraryScanner();
    final token = CancellationToken();
    final byPath = <String, Track>{};
    await for (final event in scanner.scan(Directory(path), token: token)) {
      if (event is ScanDiscovered) {
        byPath.putIfAbsent(event.track.path, () => event.track);
      }
      // ScanFailed / ScanSkipped / ScanDone: skip.
    }
    return byPath.values.toList(growable: false);
  });
}
