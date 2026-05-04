import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/browse/artist_view.dart';
import 'package:mobile/browse/genre_view.dart';
import 'package:prism_core/core.dart';

void main() {
  // 50-track fixture: 3 albums × ~16 tracks, mostly tagged, some ragged
  // edges (missing album, mixed-case artist, blank genre).
  final tracks = _fixture();

  group('indexAlbums', () {
    test('groups by (albumArtist || artist) ∷ album, falls back on missing',
        () {
      final albums = indexAlbums(tracks, const {}, const {});
      // 3 fully-tagged albums + 1 "Unknown Album" group (the tagless
      // tracks at the tail of the fixture). Slice-10c v3 case-folds
      // the id (effectiveAlbumArtist + albumKey both lowercased) so
      // case variants in the source tags collapse into a single bucket.
      final ids = albums.map((a) => a.id).toSet();
      expect(ids, contains('nirvana∷nevermind'));
      expect(ids, contains('radiohead∷ok computer'));
      expect(ids, contains('sigur rós∷ágætis byrjun'));
      expect(ids, contains('untagged artist∷unknown album'));
    });

    test('sorts by case-insensitive title then artist (stable)', () {
      final albums = indexAlbums(tracks, const {}, const {});
      final titles = albums.map((a) => a.title).toList();
      // Standard Dart String#compareTo is codepoint-ordered: lowercase
      // Latin runs ahead of accented letters (`á` U+00E1 > `z` U+007A),
      // which is why "Ágætis byrjun" lands at the end. Slice 7 polish
      // can swap in a locale-aware collator if non-Latin titles fall
      // out of natural order in real libraries.
      expect(titles, [
        'Filler LP',
        'Mystery LP',
        'Nevermind',
        'OK Computer',
        'Unknown Album',
        'Ágætis byrjun',
      ]);
    });

    test('cover lookup chases path → release MBID → CAA URL', () {
      // First Nirvana track maps to a release; CAA url present.
      final nirvanaTracks = tracks.where((t) => t.album == 'Nevermind').toList();
      final releaseMbidByPath = <String, String?>{
        for (final t in nirvanaTracks) t.path: 'rel-nevermind',
      };
      final coverByMbid = <String, String?>{
        'rel-nevermind': 'https://coverartarchive.org/release/rel-nevermind/front-500',
      };
      final albums = indexAlbums(tracks, releaseMbidByPath, coverByMbid);
      final nv = albums.firstWhere((a) => a.title == 'Nevermind');
      expect(nv.coverUrl,
          'https://coverartarchive.org/release/rel-nevermind/front-500');
      expect(nv.releaseMbid, 'rel-nevermind');

      // Other albums fall back to null cover.
      final ok = albums.firstWhere((a) => a.title == 'OK Computer');
      expect(ok.coverUrl, isNull);
    });

    test('totalDuration sums across tracks (zeroes out unknowns)', () {
      final albums = indexAlbums(tracks, const {}, const {});
      final nv = albums.firstWhere((a) => a.title == 'Nevermind');
      // 5 tracks × 4 minutes = 20 min in the fixture.
      expect(nv.totalDuration, const Duration(minutes: 20));
    });
  });

  group('indexArtists', () {
    test('counts albums + tracks per artist, sorts by name', () {
      final albums = indexAlbums(tracks, const {}, const {});
      final artists = indexArtists(tracks, albums, const {});
      final names = artists.map((a) => a.name).toList();
      // Sorted ascending by lower-cased name. Compare via String#compareTo;
      // the matcher's `lessThanOrEqualTo` is numeric-only.
      for (var i = 0; i + 1 < names.length; i++) {
        expect(
          names[i].toLowerCase().compareTo(names[i + 1].toLowerCase()),
          lessThanOrEqualTo(0),
        );
      }
      final nirvana = artists.firstWhere((a) => a.name == 'Nirvana');
      expect(nirvana.albumCount, 1);
      expect(nirvana.trackCount, 5);
      expect(nirvana.topTracks.length, 5);
    });

    test('attaches resolved MBID when artistMbidByPath has one for the group',
        () {
      final albums = indexAlbums(tracks, const {}, const {});
      final artistMbidByPath = <String, String?>{
        for (final t in tracks.where((t) => t.artist == 'Nirvana'))
          t.path: 'art-nirvana',
      };
      final artists = indexArtists(tracks, albums, artistMbidByPath);
      final nirvana = artists.firstWhere((a) => a.name == 'Nirvana');
      expect(nirvana.mbid, 'art-nirvana');
    });
  });

  group('indexGenres', () {
    test('drops empty + literal Unknown, sorts by track count desc', () {
      final genres = indexGenres(tracks);
      final labels = genres.map((g) => g.label.toLowerCase()).toList();
      expect(labels, isNot(contains('unknown')));
      expect(labels, isNot(contains('')));
      // 'rock' is the largest pile in the fixture.
      expect(labels.first, 'Rock'.toLowerCase());
    });

    test('accent is deterministic across rebuilds', () {
      final a = indexGenres(tracks);
      final b = indexGenres(tracks);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].accent, b[i].accent);
      }
    });
  });
}

List<Track> _fixture() {
  final tracks = <Track>[
    // 5× Nevermind (Nirvana, rock, 1991)
    for (var i = 0; i < 5; i++)
      Track(
        path: '/m/nv/$i.flac',
        mtimeMs: 0,
        title: 'Track $i',
        artist: 'Nirvana',
        albumArtist: 'Nirvana',
        album: 'Nevermind',
        year: 1991,
        genre: 'Rock',
        duration: const Duration(minutes: 4),
        trackNo: i + 1,
      ),
    // 5× OK Computer (Radiohead, rock, 1997)
    for (var i = 0; i < 5; i++)
      Track(
        path: '/m/ok/$i.flac',
        mtimeMs: 0,
        title: 'Subterranean $i',
        artist: 'Radiohead',
        albumArtist: 'Radiohead',
        album: 'OK Computer',
        year: 1997,
        genre: 'Rock',
        duration: const Duration(minutes: 5),
      ),
    // 5× Ágætis byrjun (Sigur Rós, post-rock, 1999)
    for (var i = 0; i < 5; i++)
      Track(
        path: '/m/sr/$i.flac',
        mtimeMs: 0,
        title: 'Svefn-G-Englar $i',
        artist: 'Sigur Rós',
        albumArtist: 'Sigur Rós',
        album: 'Ágætis byrjun',
        year: 1999,
        genre: 'Post-Rock',
        duration: const Duration(minutes: 8),
      ),
    // 3× tagless rips (Untagged Artist / Unknown Album / "" genre)
    for (var i = 0; i < 3; i++)
      Track(
        path: '/m/untag/$i.flac',
        mtimeMs: 0,
        artist: 'Untagged Artist',
        // no album → "Unknown Album"
        // no genre → drops
        duration: const Duration(minutes: 3),
      ),
    // 2× literal "Unknown" genre (should drop from genres view)
    for (var i = 0; i < 2; i++)
      Track(
        path: '/m/unkgenre/$i.flac',
        mtimeMs: 0,
        title: 'Mystery $i',
        artist: 'Mystery',
        album: 'Mystery LP',
        year: 2000,
        genre: 'Unknown',
        duration: const Duration(minutes: 3),
      ),
  ];
  // Pad to 50 with a separate Filler album so Nevermind's totalDuration
  // assertion stays at 5 × 4 = 20 min. Filler still uses 'Rock' so 'Rock'
  // remains the largest pile by track count.
  while (tracks.length < 50) {
    tracks.add(Track(
      path: '/m/filler/${tracks.length}.flac',
      mtimeMs: 0,
      title: 'Filler ${tracks.length}',
      artist: 'Filler Artist',
      albumArtist: 'Filler Artist',
      album: 'Filler LP',
      year: 2010,
      genre: 'Rock',
      duration: const Duration(minutes: 3),
    ));
  }
  return tracks;
}
