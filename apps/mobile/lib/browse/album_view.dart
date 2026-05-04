import 'package:prism_core/core.dart';

import '../providers/library_view_prefs.dart';

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

/// Pure derivation: groups [tracks] using a two-pass canonical-album-
/// artist resolution that fixes the slice-10 §2.4 grouping bug.
///
/// Pass 1 — walk every track. For each `(album-title-lower, trimmed)`
/// key, collect the multiset of distinct non-null `albumArtist` values.
/// The canonical artist for that title is the most-frequent non-null
/// entry (ties broken by first-seen order to keep grouping deterministic
/// across rebuilds).
///
/// Pass 2 — group every track. The id is
/// `<canonicalAlbumArtist OR _normalizeArtist(track.artist)> ∷ <album>`.
/// `Track.albumArtist` is never mutated; the original tag flows
/// untouched into the queue / palette / radio paths.
///
/// [releaseMbidByPath]: absolute file path → release MBID (from
/// `track_meta`).
/// [coverByReleaseMbid]: release MBID → CAA URL (from `metadata_cache`
/// rows whose `kind == 'caa'`). Either map may be empty during a cold
/// scan — albums then render the gradient fallback tile.
List<AlbumView> indexAlbums(
  List<Track> tracks,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  // Pass 1 — collect canonical album-artist hints per album title.
  final seenOrder = <String, List<String>>{};
  final counts = <String, Map<String, int>>{};
  for (final t in tracks) {
    final albumKey = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim().toLowerCase()
        : 'unknown album';
    final aa = t.albumArtist?.trim();
    if (aa == null || aa.isEmpty) continue;
    final list = seenOrder.putIfAbsent(albumKey, () => <String>[]);
    if (!list.contains(aa)) list.add(aa);
    final m = counts.putIfAbsent(albumKey, () => <String, int>{});
    m.update(aa, (c) => c + 1, ifAbsent: () => 1);
  }
  final canonicalByAlbum = <String, String>{};
  counts.forEach((albumKey, m) {
    String? bestKey;
    var bestCount = -1;
    for (final entry in seenOrder[albumKey]!) {
      final c = m[entry] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        bestKey = entry;
      }
    }
    if (bestKey != null) canonicalByAlbum[albumKey] = bestKey;
  });

  // Pass 2 — group each track using the canonical hint or the
  // normalised artist fallback.
  final groups = <String, List<Track>>{};
  final groupArtistDisplay = <String, String>{};
  for (final t in tracks) {
    final albumKey = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim().toLowerCase()
        : 'unknown album';
    final canonical = canonicalByAlbum[albumKey];
    final groupArtist = canonical ?? _normalizeArtist(t.artist ?? '');
    final albumDisplay = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim()
        : 'Unknown Album';
    final id = '$groupArtist∷$albumDisplay';
    groups.putIfAbsent(id, () => <Track>[]).add(t);
    groupArtistDisplay.putIfAbsent(id, () {
      if (groupArtist.isNotEmpty) return groupArtist;
      return 'Unknown Artist';
    });
  }
  final views = groups.entries
      .map((e) => _buildAlbumView(
            e.key,
            e.value,
            groupArtistDisplay[e.key] ?? 'Unknown Artist',
            releaseMbidByPath,
            coverByReleaseMbid,
          ))
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
  String artistDisplay,
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
    artist: artistDisplay,
    year: _firstYear(ts),
    coverUrl: coverUrl,
    releaseMbid: releaseMbid,
    tracks: List.unmodifiable(ts),
  );
}

String _albumTitle(Track t) {
  final al = t.album?.trim();
  if (al == null || al.isEmpty) return 'Unknown Album';
  return al;
}

int? _firstYear(List<Track> ts) {
  for (final t in ts) {
    if (t.year != null) return t.year;
  }
  return null;
}

/// Strips collaborator suffixes from an artist string. Case-insensitive
/// match against `feat.`, `ft.`, `featuring`, `(feat. …)`, `(with …)`.
/// `&` and `,` separators do not strip — they imply genuine multi-artist
/// credits the user usually wants kept distinct.
///
/// Single-pass regex match — strips from the first marker onward, so
/// `X feat. Y feat. Z` becomes `X`. Keeps trim semantics consistent
/// with the rest of the album indexer.
String _normalizeArtist(String input) {
  if (input.trim().isEmpty) return '';
  // The regex matches `(feat. anything-to-end)`, `(with anything)`,
  // `(ft. anything)`, `feat. ...`, `ft. ...`, `featuring ...`,
  // case-insensitively. The `\s+` before the marker prevents matching
  // inside artist names that happen to contain "ft" as a substring.
  final stripped = input.replaceFirst(
    RegExp(
      r'\s*(?:[(\[]\s*)?'
      r'(?:feat\.?|ft\.?|featuring|with)\s'
      r'.*$',
      caseSensitive: false,
    ),
    '',
  );
  return stripped.trim();
}

/// Spec §2.5 — secondary sort always falls back to title (case-
/// insensitive) so equal primary keys produce stable ordering.
/// Null-tag rows fall to the END regardless of direction.
List<AlbumView> sortAlbums(List<AlbumView> albums, AlbumSort sort) {
  final out = List<AlbumView>.from(albums);
  switch (sort) {
    case AlbumSort.title:
      out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    case AlbumSort.artist:
      out.sort((a, b) {
        final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        if (c != 0) return c;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    case AlbumSort.yearNewest:
      out.sort(_byYear(newestFirst: true));
    case AlbumSort.yearOldest:
      out.sort(_byYear(newestFirst: false));
    case AlbumSort.recentlyAdded:
      out.sort((a, b) {
        final ra = _maxAddedAtMs(a);
        final rb = _maxAddedAtMs(b);
        if (ra == null && rb == null) {
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        }
        if (ra == null) return 1;
        if (rb == null) return -1;
        final c = rb.compareTo(ra);
        if (c != 0) return c;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
  }
  return out;
}

int Function(AlbumView, AlbumView) _byYear({required bool newestFirst}) {
  return (a, b) {
    final ya = a.year;
    final yb = b.year;
    if (ya == null && yb == null) {
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    }
    if (ya == null) return 1;
    if (yb == null) return -1;
    final c = newestFirst ? yb.compareTo(ya) : ya.compareTo(yb);
    if (c != 0) return c;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  };
}

int? _maxAddedAtMs(AlbumView a) {
  // mtimeMs serves as a proxy for "added at"; AlbumView holds the raw
  // tracks, so we pick the most recent.
  int? best;
  for (final t in a.tracks) {
    if (best == null || t.mtimeMs > best) best = t.mtimeMs;
  }
  return best;
}

/// Spec §2.5 — OR-of-genres aggregate filter. An album passes when at
/// least one of its tracks tags a genre in [selectedKeys] (raw storage
/// strings — they're the actual tag values stored on disk).
List<AlbumView> filterAlbumsByGenre(
  List<AlbumView> albums,
  List<String> selectedKeys,
) {
  if (selectedKeys.isEmpty) return albums;
  final keys = selectedKeys.toSet();
  return [
    for (final a in albums)
      if (a.tracks.any((t) => t.genre != null && keys.contains(t.genre)))
        a,
  ];
}
