import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../replay_gain.dart';

/// Immutable metadata record for a single audio file discovered by the
/// library scanner.
///
/// Identity is by [path] only — two [Track]s with the same filesystem
/// path are considered equal even if their tag contents differ. This
/// keeps re-scan dedup (`Map<String, Track>.putIfAbsent`) cheap and
/// lets the queue treat tracks as addressable by path.
///
/// Non-goals for slice 1: sidecar data (`.sonic.json`), SQLite rows,
/// cover-art bytes. Those arrive in slice 4.
class Track {
  /// Absolute filesystem path. Also the identity key for `==` / `hashCode`.
  final String path;

  /// File modification time in milliseconds since epoch (UTC).
  /// Slice 4's SQLite cache uses this to decide when to re-read tags.
  final int mtimeMs;

  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final String? genre;

  final int? trackNo;
  final int? discNo;
  final int? year;

  final Duration? duration;

  /// Tag-embedded `REPLAYGAIN_TRACK_GAIN` in dB, parsed to a double.
  /// `null` if the tag is absent or the format does not expose it.
  /// Slice 1 reads only tag-embedded values; measured RG lands in slice 4.
  final double? replayGainTrackDb;

  /// Tag-embedded `REPLAYGAIN_ALBUM_GAIN` in dB, parsed to a double.
  final double? replayGainAlbumDb;

  const Track({
    required this.path,
    required this.mtimeMs,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.genre,
    this.trackNo,
    this.discNo,
    this.year,
    this.duration,
    this.replayGainTrackDb,
    this.replayGainAlbumDb,
  });

  /// Builds a [Track] from [audio_metadata_reader]'s unified [AudioMetadata]
  /// (standard fields) plus, optionally, the format-specific parser tag
  /// returned by `readAllMetadata(...)` (which slice 1 step 5 walks to
  /// resolve tag-embedded ReplayGain and album-artist).
  ///
  /// [raw] is typed `Object?` rather than the package's internal sealed
  /// `ParserTag` base (not exported) — this factory pattern-matches on
  /// the exported concrete subtypes (`Mp3Metadata`, `VorbisMetadata`).
  /// `Mp4Metadata` and `RiffMetadata` fall through to `null` because the
  /// package does not expose their iTunes-freeform / INFO-chunk
  /// ReplayGain equivalents; slice 4 can revisit.
  factory Track.fromMetadata({
    required String path,
    required int mtimeMs,
    required AudioMetadata meta,
    Object? raw,
  }) {
    return Track(
      path: path,
      mtimeMs: mtimeMs,
      title: meta.title,
      artist: meta.artist,
      albumArtist: _extractAlbumArtist(raw),
      album: meta.album,
      genre: meta.genres.isEmpty ? null : meta.genres.first,
      trackNo: meta.trackNumber,
      discNo: meta.discNumber,
      year: meta.year?.year,
      duration: meta.duration,
      replayGainTrackDb: _extractReplayGainDb(raw, isAlbum: false),
      replayGainAlbumDb: _extractReplayGainDb(raw, isAlbum: true),
    );
  }

  /// Resolves `REPLAYGAIN_TRACK_GAIN` / `REPLAYGAIN_ALBUM_GAIN` by
  /// switching on the concrete [raw] subtype:
  ///
  /// - `VorbisMetadata` (FLAC / OGG / Opus) → the first entry in the
  ///   dedicated `replayGainTrackGain` / `replayGainAlbumGain`
  ///   `List<String>` field.
  /// - `Mp3Metadata` → TXXX `customMetadata[...]`, looked up
  ///   case-insensitively (real-world taggers vary between
  ///   `REPLAYGAIN_TRACK_GAIN`, `replaygain_track_gain`, and mixed case).
  /// - anything else (`Mp4Metadata`, `RiffMetadata`, `null`) → `null`.
  static double? _extractReplayGainDb(Object? raw, {required bool isAlbum}) {
    final key = isAlbum ? 'REPLAYGAIN_ALBUM_GAIN' : 'REPLAYGAIN_TRACK_GAIN';
    final String? rawValue = switch (raw) {
      VorbisMetadata m => isAlbum
          ? (m.replayGainAlbumGain.isEmpty
              ? null
              : m.replayGainAlbumGain.first)
          : (m.replayGainTrackGain.isEmpty
              ? null
              : m.replayGainTrackGain.first),
      Mp3Metadata m => _lookupCaseInsensitive(m.customMetadata, key),
      _ => null,
    };
    return rawValue == null ? null : parseReplayGainDb(rawValue);
  }

  /// Resolves the album-artist for display / grouping. Slice 1's three
  /// screens don't yet use this (the tracks list is flat), but slice 2's
  /// Albums browse needs it — populating now costs nothing because we
  /// already hold [raw].
  static String? _extractAlbumArtist(Object? raw) => switch (raw) {
        // TPE2 — `bandOrOrchestra` on MP3s is the album-artist convention.
        Mp3Metadata m => m.bandOrOrchestra,
        // Vorbis comments don't have a dedicated field; taggers use
        // the `ALBUMARTIST` key (stored verbatim in `unknowns`).
        VorbisMetadata m => _lookupCaseInsensitive(m.unknowns, 'ALBUMARTIST'),
        _ => null,
      };

  static String? _lookupCaseInsensitive(Map<String, String> map, String key) {
    if (map.containsKey(key)) return map[key];
    final target = key.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Track && other.path == path);

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() =>
      'Track(path: $path, title: $title, artist: $artist, album: $album)';
}
