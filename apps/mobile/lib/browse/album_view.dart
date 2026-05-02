import 'package:prism_core/core.dart';

/// Stable, derived projection of one album.
///
/// Identity ([id]) is `${albumArtist ?? artist}∷${album}` — the U+2237
/// "proportion" glyph is rare enough in tag values that it works as a
/// safe separator without ever colliding with real titles.
///
/// Cover-art resolution is two-hop: a track's path → release MBID
/// (resolved by the backfill into `track_meta`) → CAA URL (resolved
/// into the `caa` cache rows). The Riverpod browse provider hands both
/// maps in; we look up the first track in each group whose path has a
/// release MBID resolved and its MBID has a CAA URL. Stable across
/// rebuilds because [tracks] preserves the input order.
///
/// **Plan note:** §7 sketches `indexAlbums(tracks, coverByReleaseMbid)`;
/// the plan implicitly assumed Track carried a `releaseMbid`. Slice 2
/// keeps `packages/core` unchanged (slice-1 contract), so we pass a
/// second `releaseMbidByPath` map instead. Net effect identical;
/// signatures differ by exactly one extra parameter.
class AlbumView {
  /// Stable id used as both the Riverpod cache key and the route param
  /// for `AlbumDetailScreen`.
  final String id;

  /// Display title. Empty/null `album` tags collapse to `'Unknown Album'`
  /// — Apple Music does the same.
  final String title;

  /// Artist string used in the grid subtitle. Prefers `albumArtist`
  /// when at least one track in the group has one, falls back to
  /// `artist`.
  final String artist;

  /// Year shown on the detail page; parsed from the first non-null
  /// `year` tag in the group.
  final int? year;

  /// CAA URL for the album front cover, when one resolved during
  /// backfill. `null` here means the tile renders the gradient
  /// fallback (no spinner forever).
  final String? coverUrl;

  /// Resolved MusicBrainz release MBID. `null` until the backfill has
  /// produced one for at least one track in the group; surfaced for
  /// `cached_network_image`'s `cacheKey` parameter so two albums that
  /// share a CAA URL still keep separate cache buckets.
  final String? releaseMbid;

  /// All tracks in the group, in the input order. The detail screen
  /// re-sorts by `(discNo, trackNo)` before rendering — keeping the
  /// raw order here keeps tests deterministic.
  final List<Track> tracks;

  const AlbumView({
    required this.id,
    required this.title,
    required this.artist,
    required this.tracks,
    this.year,
    this.coverUrl,
    this.releaseMbid,
  });

  int get trackCount => tracks.length;

  Duration get totalDuration => tracks.fold<Duration>(
        Duration.zero,
        (acc, t) => acc + (t.duration ?? Duration.zero),
      );
}

/// Pure derivation: groups [tracks] by `(albumArtist ?? artist) ∷ album`,
/// sorts albums by title (case-insensitive), and joins each group with
/// the resolved cover URL when available.
///
/// [releaseMbidByPath]: absolute file path → release MBID (from
/// `track_meta`).
/// [coverByReleaseMbid]: release MBID → CAA URL (from `metadata_cache`
/// rows whose `kind == 'caa'`). Either map may be empty during a cold
/// scan — albums then render the gradient fallback tile.
///
/// Why we don't sort by year: slice 7 polish does an Apple Music-style
/// "Year added → year released" sort with a setting; for slice 2 a
/// title sort is the predictable default so the ordering is identical
/// across rebuilds.
List<AlbumView> indexAlbums(
  List<Track> tracks,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  final groups = <String, List<Track>>{};
  for (final t in tracks) {
    groups.putIfAbsent(_idFor(t), () => []).add(t);
  }
  final views = groups.entries
      .map((e) => _buildAlbumView(
          e.key, e.value, releaseMbidByPath, coverByReleaseMbid))
      .toList()
    ..sort((a, b) {
      final t = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (t != 0) return t;
      return a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
    });
  return views;
}

AlbumView _buildAlbumView(
  String id,
  List<Track> ts,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  String? releaseMbid;
  String? coverUrl;
  for (final t in ts) {
    final mbid = releaseMbidByPath[t.path];
    if (mbid != null) {
      releaseMbid ??= mbid;
      final url = coverByReleaseMbid[mbid];
      if (url != null) {
        coverUrl = url;
        break;
      }
    }
  }
  return AlbumView(
    id: id,
    title: _albumTitle(ts.first),
    artist: _albumArtist(ts.first),
    year: _firstYear(ts),
    coverUrl: coverUrl,
    releaseMbid: releaseMbid,
    tracks: List.unmodifiable(ts),
  );
}

String _idFor(Track t) {
  final aa = (t.albumArtist?.trim().isNotEmpty ?? false)
      ? t.albumArtist!.trim()
      : (t.artist?.trim() ?? '');
  final al = (t.album?.trim().isNotEmpty ?? false)
      ? t.album!.trim()
      : 'Unknown Album';
  // U+2237 PROPORTION as a separator that cannot appear in a real tag.
  return '$aa∷$al';
}

String _albumTitle(Track t) {
  final al = t.album?.trim();
  if (al == null || al.isEmpty) return 'Unknown Album';
  return al;
}

String _albumArtist(Track t) {
  final aa = t.albumArtist?.trim();
  if (aa != null && aa.isNotEmpty) return aa;
  final a = t.artist?.trim();
  if (a != null && a.isNotEmpty) return a;
  return 'Unknown Artist';
}

int? _firstYear(List<Track> ts) {
  for (final t in ts) {
    if (t.year != null) return t.year;
  }
  return null;
}
