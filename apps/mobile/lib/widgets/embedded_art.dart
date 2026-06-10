import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// [ImageProvider] that reads the first embedded picture (typically
/// the FLAC PICTURE block / ID3 APIC frame / MP4 covr atom) from an
/// audio file at [path] and decodes it.
///
/// Cheap to construct; the actual file read + decode happens lazily
/// when Flutter's [PaintingBinding.imageCache] does not have an entry
/// keyed on this provider. Equality is by [path], so two widgets that
/// point at the same audio file share the same cached decoded image.
///
/// **Why this exists.** The library scanner reads tags but explicitly
/// passes `getImage: false` to keep the cold-scan fast — embedded
/// pictures can be 5 MB+ each. This provider does the on-demand read
/// from a single track's path, isolated to the screens that actually
/// need to *look* at the art (album tile, now-playing).
@immutable
class EmbeddedArtImage extends ImageProvider<EmbeddedArtImage> {
  const EmbeddedArtImage(this.path, {this.scale = 1.0});

  /// Absolute filesystem path to the audio file that owns the art.
  final String path;

  /// Scale factor passed through to the [ImageInfo].
  final double scale;

  @override
  Future<EmbeddedArtImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<EmbeddedArtImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    EmbeddedArtImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadCodec(key, decode),
      scale: key.scale,
      debugLabel: 'EmbeddedArtImage("$path")',
    );
  }

  Future<ui.Codec> _loadCodec(
    EmbeddedArtImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await readEmbeddedArtBytes(key.path);
    if (bytes == null || bytes.isEmpty) {
      // Tell the framework "no art, render the error widget" rather
      // than producing a 0×0 frame that paints empty.
      throw StateError('No embedded picture in $path');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EmbeddedArtImage &&
          other.path == path &&
          other.scale == scale);

  @override
  int get hashCode => Object.hash(path, scale);

  @override
  String toString() => 'EmbeddedArtImage("$path", scale: $scale)';
}

/// Returns the bytes of the first embedded picture in the file at
/// [path], or `null` if the file has no parser, no pictures, or
/// fails to read for any reason.
///
/// Off-loaded to a background isolate via [compute] so a 5 MB FLAC
/// PICTURE block doesn't jank the UI thread on first paint.
Future<Uint8List?> readEmbeddedArtBytes(String path) async {
  try {
    return await compute(_readArtIsolate, path);
  } catch (_) {
    return null;
  }
}

Uint8List? _readArtIsolate(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final meta = readMetadata(file, getImage: true);
    if (meta.pictures.isEmpty) return null;
    // Prefer "Cover (front)" if present; otherwise take the first
    // picture. `pictureType` enums vary across formats — falling
    // back to `[0]` keeps OGG / MP4 covers reachable.
    Picture? front;
    for (final p in meta.pictures) {
      if (p.pictureType == PictureType.coverFront) {
        front = p;
        break;
      }
    }
    return (front ?? meta.pictures.first).bytes;
  } catch (_) {
    return null;
  }
}
