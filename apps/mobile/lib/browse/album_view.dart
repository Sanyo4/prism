import 'package:path/path.dart' as p;
import 'package:prism_core/core.dart';

import '../providers/library_view_prefs.dart';

/// Stable, derived projection of one album.
///
/// Identity ([id]) is `${effectiveAlbumArtist.toLowerCase()}∷${album.toLowerCase()}`
/// — the U+2237 "proportion" glyph is rare enough in tag values that it
/// works as a safe separator without ever colliding with real titles.
/// Slice-10c case-folded the id so two tracks tagged "The Album" and
/// "the album" collapse into one group; display fields preserve the
/// dominant original case.
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

/// Pure derivation: groups [tracks] Strawberry-style on
/// `(effectiveAlbumArtist, album)`, collapsing case variants and
/// detecting Various Artists compilations.
///
/// **Algorithm (slice-10c v3):**
///
/// 1. **Derive entries.** For each track:
///    - `effectiveAA = albumArtist?.trim()` if non-empty, else
///      `artist?.trim()`. Pure null-coalesce — no `feat./ft.`
///      stripping, no lowercase, no normalization.
///    - `albumKey = album?.trim()`, falling back to `'Unknown Album'`.
///
/// 2. **Detect compilations.** Bucket entries by case-folded album
///    title. A bucket is treated as a Various Artists compilation
///    when EITHER:
///    - any track's `effectiveAA` already reads "various artists"
///      (case-insensitive); OR
///    - all tracks in the bucket share a single parent directory
///      AND the bucket has ≥3 distinct case-folded effective artists.
///    For a VA bucket, every entry's `effectiveAA` is canonicalised
///    to literal `"Various Artists"`.
///
/// 3. **Group by case-folded id.** `id = lower(effectiveAA) ∷
///    lower(albumKey)`. Same id ⇒ same group, regardless of the tag's
///    original case. Display fields (`title`, `artist`) pick the
///    most-frequent original-case form across the group's tracks
///    (ties broken by first-seen order), so the dominant tag style
///    wins without lowercasing the UI.
///
/// **Non-destructive guarantees** (slice-10 §2.4): `Track.albumArtist`
/// and `Track.artist` are never mutated. The original tag values flow
/// untouched into the queue, palette, and radio paths; only the
/// derived projection sees the canonical "Various Artists" string.
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
  // Pass 1 — derive the raw effective album-artist + album for each track.
  final entries = <_Entry>[];
  for (final t in tracks) {
    final aa = (t.albumArtist ?? '').trim();
    final artistFallback = (t.artist ?? '').trim();
    final albumName = (t.album ?? '').trim();
    final effectiveAA = aa.isNotEmpty ? aa : artistFallback;
    final albumKey = albumName.isEmpty ? 'Unknown Album' : albumName;
    entries.add(_Entry(track: t, effectiveAA: effectiveAA, albumKey: albumKey));
  }

  // Pass 2 — Various-Artists detection. Bucket by case-folded album title;
  // collapse compilations under the canonical "Various Artists" string.
  final byAlbumLower = <String, List<_Entry>>{};
  for (final e in entries) {
    byAlbumLower.putIfAbsent(e.albumKey.toLowerCase(), () => <_Entry>[]).add(e);
  }
  for (final cluster in byAlbumLower.values) {
    final tagSaysVA = cluster.any(
      (e) => e.effectiveAA.toLowerCase() == 'various artists',
    );
    final allBlankAA = cluster.every(
      (e) => (e.track.albumArtist == null || e.track.albumArtist!.trim().isEmpty),
    );
    final distinctArtists =
        cluster.map((e) => e.effectiveAA.toLowerCase()).toSet();
    final parentDirs = cluster.map((e) => p.dirname(e.track.path)).toSet();
    final isHeuristicVA = allBlankAA &&
        distinctArtists.length >= 3 &&
        parentDirs.length == 1;
    if (tagSaysVA || isHeuristicVA) {
      for (final e in cluster) {
        e.effectiveAA = 'Various Artists';
      }
    }
  }

  // Pass 3 — group by case-folded id; pick most-common original-case
  // form for display fields.
  final byId = <String, _Group>{};
  for (final e in entries) {
    final id = '${e.effectiveAA.toLowerCase()}∷${e.albumKey.toLowerCase()}';
    final g = byId.putIfAbsent(id, () => _Group(id: id));
    g.tracks.add(e.track);
    if (e.effectiveAA.isNotEmpty) {
      g.aaCounts.update(e.effectiveAA, (c) => c + 1, ifAbsent: () => 1);
      g.aaOrder.putIfAbsent(e.effectiveAA, () => g.aaOrder.length);
    }
    g.albumCounts.update(e.albumKey, (c) => c + 1, ifAbsent: () => 1);
    g.albumOrder.putIfAbsent(e.albumKey, () => g.albumOrder.length);
  }

  final views = byId.values
      .map((g) => _buildAlbumView(
            g,
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
  _Group g,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  String? releaseMbid;
  String? coverUrl;
  for (final t in g.tracks) {
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
  final dominantAA = _mostCommon(g.aaCounts, g.aaOrder) ?? 'Unknown Artist';
  final dominantAlbum =
      _mostCommon(g.albumCounts, g.albumOrder) ?? 'Unknown Album';
  return AlbumView(
    id: g.id,
    title: dominantAlbum,
    artist: dominantAA,
    year: _firstYear(g.tracks),
    coverUrl: coverUrl,
    releaseMbid: releaseMbid,
    tracks: List.unmodifiable(g.tracks),
  );
}

int? _firstYear(List<Track> ts) {
  for (final t in ts) {
    if (t.year != null) return t.year;
  }
  return null;
}

/// Picks the most-frequent string from [counts]. Ties are broken by the
/// first-seen order recorded in [order] (lower index wins), so grouping
/// stays deterministic across rebuilds and the dominant tag style ("The
/// Album" vs "the album") in the source data shows through.
String? _mostCommon(Map<String, int> counts, Map<String, int> order) {
  if (counts.isEmpty) return null;
  String? best;
  var bestCount = -1;
  var bestOrder = 1 << 30;
  counts.forEach((value, count) {
    final ord = order[value] ?? (1 << 30);
    if (count > bestCount || (count == bestCount && ord < bestOrder)) {
      best = value;
      bestCount = count;
      bestOrder = ord;
    }
  });
  return best;
}

/// Internal carrier between Pass 1 and Pass 3. `effectiveAA` is mutable
/// so Pass 2 can rewrite it to the canonical "Various Artists" string
/// for compilation buckets — `Track.albumArtist` itself stays verbatim.
class _Entry {
  final Track track;
  String effectiveAA;
  final String albumKey;

  _Entry({
    required this.track,
    required this.effectiveAA,
    required this.albumKey,
  });
}

/// Internal accumulator. Tracks frequency + first-seen order of each
/// original-case tag so [_buildAlbumView] can pick the dominant display
/// form per group.
class _Group {
  final String id;
  final List<Track> tracks = <Track>[];
  final Map<String, int> aaCounts = <String, int>{};
  final Map<String, int> aaOrder = <String, int>{};
  final Map<String, int> albumCounts = <String, int>{};
  final Map<String, int> albumOrder = <String, int>{};

  _Group({required this.id});
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
