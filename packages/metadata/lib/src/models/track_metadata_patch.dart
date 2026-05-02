/// What the BackfillQueue produces for a single track. The app
/// applies it to its in-memory `Track` (via `trackPatchProvider`) so
/// browse rows update in place without a full re-scan.
///
/// Every field is nullable — only fields the user's tags were
/// *missing* get filled. Tag-embedded values always win; we never
/// overwrite something the user explicitly set in their files.
class TrackMetadataPatch {
  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final String? genre;
  final int? year;
  final int? trackNo;
  final int? discNo;

  /// Resolved MusicBrainz IDs — surfaced for slice 4 (sidecar ingest)
  /// and the artist-detail page (Last.fm bio lookup keyed on
  /// [artistMbid]).
  final String? recordingMbid;
  final String? releaseMbid;
  final String? artistMbid;

  /// CAA URL when a release MBID resolved and CAA had art.
  /// `cached_network_image` reads it.
  final String? coverUrl;

  const TrackMetadataPatch({
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.genre,
    this.year,
    this.trackNo,
    this.discNo,
    this.recordingMbid,
    this.releaseMbid,
    this.artistMbid,
    this.coverUrl,
  });

  /// Sentinel for "we tried, found nothing useful". The repository
  /// returns this rather than throwing on cache hits with empty
  /// payloads — keeps the BackfillQueue's loop body branch-free.
  static const empty = TrackMetadataPatch();

  bool get isEmpty =>
      title == null &&
      artist == null &&
      albumArtist == null &&
      album == null &&
      genre == null &&
      year == null &&
      trackNo == null &&
      discNo == null &&
      recordingMbid == null &&
      releaseMbid == null &&
      artistMbid == null &&
      coverUrl == null;

  bool get isNotEmpty => !isEmpty;
}
