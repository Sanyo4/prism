import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:prism_core/core.dart';

void main() {
  group('indexAlbums (slice-10c v3 — Strawberry-style grouping)', () {
    test('albumArtist priority: 9 tracks tagged X collapse with the 10th', () {
      // 9 tracks tag albumArtist=X. Track 10 leaves albumArtist null and
      // tags artist="X feat. Y" — under the v3 algorithm the effective
      // album-artist for track 10 is the verbatim "X feat. Y" (no
      // feat./ft. stripping). That's a different effectiveAA from "X",
      // so the case-folded id buckets them separately. We expect TWO
      // groups now; the documented v3 behaviour is "match Strawberry —
      // collaborator suffixes are part of the artist string". Users who
      // want the collab to fold in should tag albumArtist=X on track 10.
      final tracks = <Track>[
        for (var i = 0; i < 9; i++)
          Track(
            path: '/a/$i.flac',
            mtimeMs: 0,
            title: 'Track $i',
            artist: 'X',
            albumArtist: 'X',
            album: 'Greatest Hits',
          ),
        const Track(
          path: '/a/9.flac',
          mtimeMs: 0,
          title: 'Track 9',
          artist: 'X feat. Y',
          albumArtist: null,
          album: 'Greatest Hits',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      // 9 tracks under "X∷greatest hits" + 1 track under
      // "x feat. y∷greatest hits".
      expect(out, hasLength(2),
          reason: 'Strawberry-style grouping does not strip feat./ft.; '
              'the lone untagged-albumArtist track produces a second group.');
      final main = out.firstWhere((a) => a.tracks.length == 9);
      expect(main.title, 'Greatest Hits');
      expect(main.artist, 'X');
    });

    test('albumArtist always wins over artist when present (case-preserved)',
        () {
      final tracks = <Track>[
        const Track(
          path: '/a/1.flac',
          mtimeMs: 0,
          title: 'A',
          artist: 'X feat. Y',
          albumArtist: 'X',
          album: 'Album',
        ),
        const Track(
          path: '/a/2.flac',
          mtimeMs: 0,
          title: 'B',
          artist: 'X feat. Z',
          albumArtist: 'X',
          album: 'Album',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1));
      expect(out.single.artist, 'X');
      expect(out.single.id, 'x∷album');
    });

    test('Track.albumArtist is never mutated', () {
      const original = Track(
        path: '/f/1.flac',
        mtimeMs: 0,
        artist: 'X feat. Y',
        albumArtist: null,
        album: 'A',
      );
      indexAlbums([original], const {}, const {});
      expect(original.albumArtist, isNull);
      expect(original.artist, 'X feat. Y');
    });

    // ---- New v3 behaviour: case-folded id, dominant-case display. ------

    test('case-mismatch in album field collapses; display = dominant case',
        () {
      // Two tracks tag album="The Album", three tag album="the album".
      // v3 case-folds the id so all five group together; display picks
      // the most-frequent original case ("the album").
      final tracks = <Track>[
        const Track(
          path: '/g/1.flac',
          mtimeMs: 0,
          artist: 'X',
          albumArtist: 'X',
          album: 'The Album',
        ),
        const Track(
          path: '/g/2.flac',
          mtimeMs: 0,
          artist: 'X',
          albumArtist: 'X',
          album: 'The Album',
        ),
        const Track(
          path: '/g/3.flac',
          mtimeMs: 0,
          artist: 'X',
          albumArtist: 'X',
          album: 'the album',
        ),
        const Track(
          path: '/g/4.flac',
          mtimeMs: 0,
          artist: 'X',
          albumArtist: 'X',
          album: 'the album',
        ),
        const Track(
          path: '/g/5.flac',
          mtimeMs: 0,
          artist: 'X',
          albumArtist: 'X',
          album: 'the album',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1),
          reason: 'case-folded id should collapse "The Album"/"the album"');
      expect(out.single.title, 'the album',
          reason: 'dominant case (3 tracks) wins over "The Album" (2 tracks)');
      expect(out.single.id, 'x∷the album');
      expect(out.single.tracks, hasLength(5));
    });

    test('case-mismatch in albumArtist field collapses', () {
      final tracks = <Track>[
        const Track(
          path: '/h/1.flac',
          mtimeMs: 0,
          artist: 'The Band',
          albumArtist: 'The Band',
          album: 'Album',
        ),
        const Track(
          path: '/h/2.flac',
          mtimeMs: 0,
          artist: 'The Band',
          albumArtist: 'The band',
          album: 'Album',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1));
      expect(out.single.tracks, hasLength(2));
      expect(out.single.id, 'the band∷album');
    });

    test('Various Artists tag (any case) collapses despite artist diversity',
        () {
      // Six tracks share albumArtist="VARIOUS ARTISTS" / "Various Artists" /
      // "various artists" but each has a different per-track artist. v3
      // recognises the literal VA tag and groups them all under the
      // canonical "Various Artists" display string.
      final tracks = <Track>[
        const Track(
          path: '/v/1.flac',
          mtimeMs: 0,
          artist: 'Artist A',
          albumArtist: 'VARIOUS ARTISTS',
          album: 'Compilation',
        ),
        const Track(
          path: '/v/2.flac',
          mtimeMs: 0,
          artist: 'Artist B',
          albumArtist: 'Various Artists',
          album: 'Compilation',
        ),
        const Track(
          path: '/v/3.flac',
          mtimeMs: 0,
          artist: 'Artist C',
          albumArtist: 'various artists',
          album: 'Compilation',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1),
          reason: 'literal Various Artists tag should collapse the bucket');
      expect(out.single.artist, 'Various Artists',
          reason: 'display normalises to canonical mixed-case form');
      expect(out.single.id, 'various artists∷compilation');
      expect(out.single.tracks, hasLength(3));
    });

    test(
        'heuristic VA: 3+ artists, no albumArtist, same parent dir → '
        'collapses', () {
      // Folder of /comp/*.flac with no albumArtist anywhere and four
      // distinct per-track artists. v3 sniffs this as a compilation
      // and assigns "Various Artists" to all tracks.
      final tracks = <Track>[
        const Track(
          path: '/comp/01.flac',
          mtimeMs: 0,
          artist: 'Artist A',
          album: 'Various Mix',
        ),
        const Track(
          path: '/comp/02.flac',
          mtimeMs: 0,
          artist: 'Artist B',
          album: 'Various Mix',
        ),
        const Track(
          path: '/comp/03.flac',
          mtimeMs: 0,
          artist: 'Artist C',
          album: 'Various Mix',
        ),
        const Track(
          path: '/comp/04.flac',
          mtimeMs: 0,
          artist: 'Artist D',
          album: 'Various Mix',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1),
          reason: 'compilation heuristic should fold 4 distinct artists '
              'in the same directory into one VA group');
      expect(out.single.artist, 'Various Artists');
      expect(out.single.tracks, hasLength(4));
    });

    test(
        'heuristic VA does NOT trigger when tracks live in different '
        'directories', () {
      // 3 distinct artists / no albumArtist BUT the tracks scatter
      // across separate folders — that's three separate one-track
      // albums, not a compilation.
      final tracks = <Track>[
        const Track(
          path: '/folder1/01.flac',
          mtimeMs: 0,
          artist: 'Artist A',
          album: 'Self-Titled',
        ),
        const Track(
          path: '/folder2/01.flac',
          mtimeMs: 0,
          artist: 'Artist B',
          album: 'Self-Titled',
        ),
        const Track(
          path: '/folder3/01.flac',
          mtimeMs: 0,
          artist: 'Artist C',
          album: 'Self-Titled',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(3),
          reason: 'three different artists across three folders are '
              'three different albums, not a compilation');
    });

    test(
        'heuristic VA does NOT trigger when even one track has albumArtist',
        () {
      // 4 tracks, 4 distinct artists, same dir, BUT track #2 tags
      // albumArtist="Artist B". The heuristic requires ALL tracks to
      // lack albumArtist — otherwise the user has expressed intent.
      final tracks = <Track>[
        const Track(
          path: '/comp2/01.flac',
          mtimeMs: 0,
          artist: 'Artist A',
          album: 'Mix',
        ),
        const Track(
          path: '/comp2/02.flac',
          mtimeMs: 0,
          artist: 'Artist B',
          albumArtist: 'Artist B',
          album: 'Mix',
        ),
        const Track(
          path: '/comp2/03.flac',
          mtimeMs: 0,
          artist: 'Artist C',
          album: 'Mix',
        ),
        const Track(
          path: '/comp2/04.flac',
          mtimeMs: 0,
          artist: 'Artist D',
          album: 'Mix',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      // Four artists → four groups. (No VA collapse.)
      expect(out, hasLength(4));
    });
  });
}
