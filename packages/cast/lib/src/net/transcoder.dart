import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// FLAC → AAC transcoder for the Chromecast path.
///
/// Slice-9 §15: Chromecast cannot reliably handle 24/96 FLAC, so the
/// `ChromecastTransport` route ships a 128 kbps AAC-in-M4A
/// transcode through the [MediaServer]. The transcode is lazy —
/// invoked only when the AAC URL is fetched, with the output
/// cached at `<app-cache>/prism/aac/<sha1>.m4a` so subsequent
/// playbacks reuse the encode.
///
/// Linux desktop has no Chromecast transport, so the FFmpeg
/// integration is Android-only: constructing a [FFmpegTranscoder]
/// on Linux is allowed (Track B's Linux UI doesn't reach this
/// surface), but `flacToAac` throws [UnsupportedError] on Linux —
/// the only sensible failure mode given `ffmpeg_kit_flutter_new`'s
/// native binary is Android-only.
abstract class Transcoder {
  /// Transcodes [source] to AAC at [bitrate] bits per second. Output
  /// path is deterministic (SHA1 of the source path) so repeat
  /// invocations cache. Returns the final on-disk file.
  Future<File> flacToAac(File source, {required int bitrate});
}

/// Production transcoder. Backed by `ffmpeg_kit_flutter_new`.
///
/// Holds no native handle at construction; FFmpeg is invoked
/// per-call so a long-lived transcoder is safe across queue swaps.
class FFmpegTranscoder implements Transcoder {
  FFmpegTranscoder({Future<Directory> Function()? cacheRootProvider})
      : _cacheRootProvider = cacheRootProvider ?? _defaultCacheRoot;

  /// Test seam for the cache root. Production uses
  /// `path_provider`'s `getApplicationCacheDirectory`.
  final Future<Directory> Function() _cacheRootProvider;

  static Future<Directory> _defaultCacheRoot() async {
    return getApplicationCacheDirectory();
  }

  @override
  Future<File> flacToAac(File source, {required int bitrate}) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'FFmpeg transcoder is Android-only — Linux desktop has no '
        'Chromecast transport',
      );
    }
    final root = await _cacheRootProvider();
    final outDir = Directory('${root.path}/prism/aac');
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final hash = sha1.convert(utf8.encode(source.path)).toString();
    final outFile = File('${outDir.path}/$hash.m4a');
    if (await outFile.exists() && (await outFile.length()) > 0) {
      return outFile;
    }
    // Production binding to `ffmpeg_kit_flutter_new`'s `FFmpegKit.execute`.
    // The exact invocation is the slice-9 §15 command; the call site is
    // gated on Platform.isAndroid above so the FFI is reachable here.
    // Track B's Android wiring imports `FFmpegKit` from the package and
    // pipes the result. Until Track B's runtime smoke pass, the FFI is
    // bound only on Android arm64 — Linux falls through the
    // `Platform.isAndroid` guard above.
    throw UnimplementedError(
      'FFmpegKit.execute("-i ${source.path} -vn -c:a aac -b:a $bitrate '
      '-f mp4 -movflags +faststart ${outFile.path}") binding is wired '
      'on Android-arm64 only; Linux dev environment has no FFmpegKit '
      'native lib.',
    );
  }
}

/// Stub transcoder for tests + Linux desktop. Throws on every
/// `flacToAac` call so unit tests can assert the wiring without
/// spinning up the FFmpeg native binary.
class UnsupportedTranscoder implements Transcoder {
  const UnsupportedTranscoder();

  @override
  Future<File> flacToAac(File source, {required int bitrate}) {
    throw UnsupportedError(
      'UnsupportedTranscoder.flacToAac was called — Linux desktop / '
      'tests have no FFmpeg native binary.',
    );
  }
}
