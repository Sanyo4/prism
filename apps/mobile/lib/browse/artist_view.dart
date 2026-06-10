import 'package:prism_core/core.dart';

import '../providers/library_view_prefs.dart';
import 'album_view.dart';

/// Stable, derived projection of one artist surface.
///
/// [id] is `albumArtist ?? artist`, lower-cased, trimmed — that
/// matches the natural grouping users expect (Sigur Rós tracks
/// credited as both `Sigur Rós` and `Sigur Ros` collapse if the user
/// has consistent album-artist tags).
class ArtistView {
  final String id;
  final String name;
  final int albumCount;
  final int trackCount;

  /// Resolved MBID — first non-null `artistMbid` from the merged
  /// patches. Used by the detail screen to call
  /// `artistInfoProvider(mbid)` for the Last.fm bio.
  final String? mbid;

  /// Albums by this artist, sorted year-desc then title-asc. Used by
  /// the artist-detail page.
  final List<AlbumView> albums;

  /// Top-tracks placeholder. Slice 2 has no play-count yet, so we
  /// substitute the five longest tracks — surprisingly close to "the
  /// album openers / climaxes" on most rock libraries. Slice 4 swaps
  /// in a sidecar-derived popularity score.
  final List<Track> topTracks;

  const ArtistView({
    required this.id,
    required this.name,
    required this.albumCount,
    required this.trackCount,
    required this.albums,
    required this.topTracks,
    this.mbid,
  });
}

/// Indexes the artist surface from already-built [albums] (so the
/// album/grouping heuristic lives in one place) plus the original
/// tracks (so we can pick top-by-duration). [artistMbidByPath] lets
/// the detail page render Last.fm content.
List<ArtistView> indexArtists(
  List<Track> tracks,
  List<AlbumView> albums,
  Map<String, String?> artistMbidByPath,
) {
  // Group albums by artist id.
  final byArtistId = <String, List<AlbumView>>{};
  final nameById = <String, String>{};
  for (final al in albums) {
    final id = _artistIdFor(al.artist);
    byArtistId.putIfAbsent(id, () => []).add(al);
    nameById[id] = al.artist;
  }

  // Group tracks by artist id (for trackCount + topTracks).
  final tracksByArtistId = <String, List<Track>>{};
  for (final t in tracks) {
    final aa = (t.albumArtist?.trim().isNotEmpty ?? false)
        ? t.albumArtist!.trim()
        : (t.artist?.trim().isNotEmpty ?? false ? t.artist!.trim() : '');
    if (aa.isEmpty) continue;
    tracksByArtistId.putIfAbsent(_artistIdFor(aa), () => []).add(t);
  }

  // Resolve MBIDs: scan tracks; first non-null wins.
  final mbidByArtistId = <String, String>{};
  for (final entry in tracksByArtistId.entries) {
    for (final t in entry.value) {
      final m = artistMbidByPath[t.path];
      if (m != null) {
        mbidByArtistId[entry.key] = m;
        break;
      }
    }
  }

  return byArtistId.entries.map((e) {
    final id = e.key;
    final als = List.of(e.value)
      ..sort((a, b) {
        final ya = a.year ?? -1;
        final yb = b.year ?? -1;
        if (ya != yb) return yb.compareTo(ya);
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    final ts = tracksByArtistId[id] ?? const <Track>[];
    final top = List.of(ts)
      ..sort((a, b) =>
          (b.duration ?? Duration.zero).compareTo(a.duration ?? Duration.zero));
    return ArtistView(
      id: id,
      name: nameById[id] ?? id,
      albumCount: als.length,
      trackCount: ts.length,
      albums: List.unmodifiable(als),
      topTracks: List.unmodifiable(top.take(5)),
      mbid: mbidByArtistId[id],
    );
  }).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

String _artistIdFor(String name) => name.trim().toLowerCase();

/// Spec §2.5 sort helpers for ArtistView. Same null-tag-falls-to-end
/// semantics as albums.
List<ArtistView> sortArtists(List<ArtistView> artists, ArtistSort sort) {
  final out = List<ArtistView>.from(artists);
  switch (sort) {
    case ArtistSort.name:
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    case ArtistSort.albumCountDesc:
      out.sort((a, b) {
        final c = b.albumCount.compareTo(a.albumCount);
        if (c != 0) return c;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    case ArtistSort.recentlyAdded:
      out.sort((a, b) {
        final ra = _maxArtistMtime(a);
        final rb = _maxArtistMtime(b);
        if (ra == null && rb == null) {
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        if (ra == null) return 1;
        if (rb == null) return -1;
        final c = rb.compareTo(ra);
        if (c != 0) return c;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }
  return out;
}

int? _maxArtistMtime(ArtistView a) {
  int? best;
  for (final al in a.albums) {
    for (final t in al.tracks) {
      if (best == null || t.mtimeMs > best) best = t.mtimeMs;
    }
  }
  return best;
}

/// Artist genre filter. Artist passes when ANY track on ANY of their
/// albums matches a selected genre key.
List<ArtistView> filterArtistsByGenre(
  List<ArtistView> artists,
  List<String> selectedKeys,
) {
  if (selectedKeys.isEmpty) return artists;
  final keys = selectedKeys.toSet();
  return [
    for (final a in artists)
      if (a.albums.any((al) =>
          al.tracks.any((t) => t.genre != null && keys.contains(t.genre))))
        a,
  ];
}
