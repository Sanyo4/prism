import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../models/track.dart';
import '../paths/audio_paths.dart';
import 'cancellation_token.dart';
import 'scan_event.dart';

/// Walks a directory tree breadth-first, reading tags from every file
/// whose extension appears in [kSupportedExtensions], and yields one
/// [ScanEvent] per entry plus a terminal [ScanDone].
///
/// Guarantees:
/// - Emits [ScanDone] **exactly once**, even on cancellation or a
///   missing root directory.
/// - Per-file exceptions become [ScanFailed]; the walk continues.
/// - Honors [CancellationToken.isCancelled] between files — cancellation
///   produces `ScanDone(cancelled: true)` without raising.
///
/// Lives in `packages/core` so it's reachable from `dart test` without a
/// Flutter runtime; the `dart:io` import is SDK-level, not Flutter.
class LibraryScanner {
  LibraryScanner({Set<String>? extensions})
      : _extensions = extensions ?? kSupportedExtensions;

  final Set<String> _extensions;

  /// Starts walking [root] recursively and yields [ScanEvent]s as it
  /// goes. The returned stream is single-subscription and completes
  /// after emitting [ScanDone]. Safe to abandon early — consuming
  /// `.first` will cut the stream and abort the walk.
  Stream<ScanEvent> scan(
    Directory root, {
    required CancellationToken token,
  }) async* {
    if (token.isCancelled) {
      yield const ScanDone(cancelled: true, count: 0);
      return;
    }
    if (!await root.exists()) {
      yield ScanFailed(root.path, 'root does not exist');
      yield const ScanDone(cancelled: false, count: 0);
      return;
    }

    var count = 0;
    await for (final entity
        in root.list(recursive: true, followLinks: false)) {
      if (token.isCancelled) {
        yield ScanDone(cancelled: true, count: count);
        return;
      }
      if (entity is! File) continue;

      final path = entity.path;
      final ext = _extensionOf(path);
      if (!_extensions.contains(ext)) {
        yield ScanSkipped(path, 'unsupported extension: $ext');
        continue;
      }

      try {
        final meta = readMetadata(entity);
        Object? raw;
        try {
          raw = readAllMetadata(entity, getImage: false);
        } catch (_) {
          // Standard metadata succeeded; format-specific tag is a
          // best-effort extra (drives Step 5's ReplayGain resolution).
          raw = null;
        }
        final stat = await entity.stat();
        final track = Track.fromMetadata(
          path: path,
          mtimeMs: stat.modified.toUtc().millisecondsSinceEpoch,
          meta: meta,
          raw: raw,
        );
        yield ScanDiscovered(track);
        count++;
      } catch (error) {
        yield ScanFailed(path, error);
      }
    }
    yield ScanDone(cancelled: false, count: count);
  }

  /// Returns the lower-cased file extension including the leading dot,
  /// or an empty string if there is none.
  static String _extensionOf(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot).toLowerCase();
  }
}
