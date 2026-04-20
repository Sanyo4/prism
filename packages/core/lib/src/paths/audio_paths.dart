import 'dart:io';

/// Audio file extensions recognized by the library scanner.
///
/// Slice 1 targets the formats with native `just_audio` + ExoPlayer /
/// system-backend support that also have `audio_metadata_reader` parsers.
/// Lower-case only — the scanner normalizes the extension before lookup.
///
/// Adding a format means: (1) `just_audio` must decode it on both
/// Android and Linux; (2) `audio_metadata_reader` must produce an
/// [AudioMetadata] for it. Opus is included because FLAC-quality
/// streaming rips commonly land as `.opus`.
const Set<String> kSupportedExtensions = <String>{
  '.flac',
  '.mp3',
  '.m4a',
  '.ogg',
  '.opus',
  '.wav',
};

/// Resolves the platform-appropriate default music library root used as
/// the scanner's starting point when the user has not configured one
/// (a later slice will add a Settings row to override this; not in
/// slice 2's goals as currently scoped).
///
/// Resolution order:
/// - **Linux**: `$HOME/Music`.
/// - **Android**: `/storage/emulated/0/Music` (user-facing shared storage).
/// - **Other / unresolved**: `null`; callers should fall back to
///   `path_provider.getApplicationDocumentsDirectory()` at the app
///   layer so `packages/core` stays Flutter-free.
///
/// No I/O is performed here — the caller is responsible for checking
/// existence / readability before kicking off a scan.
Directory? defaultLibraryRoot() {
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return Directory('$home/Music');
  }
  if (Platform.isAndroid) {
    return Directory('/storage/emulated/0/Music');
  }
  return null;
}
