import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:prism_core/core.dart';

void main() {
  group('indexAlbums (slice-10 two-pass canonical resolution)', () {
    test('canonical albumArtist wins when 9/10 tracks tag it', () {
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
      expect(out, hasLength(1),
          reason: 'all 10 tracks should collapse into one album group');
      expect(out.single.title, 'Greatest Hits');
      expect(out.single.artist, 'X');
      expect(out.single.tracks, hasLength(10));
    });

    test('no albumArtist anywhere, normalises feat./ft./featuring/with', () {
      final tracks = <Track>[
        const Track(
          path: '/b/1.flac',
          mtimeMs: 0,
          title: 'A',
          artist: 'X',
          album: 'Album',
        ),
        const Track(
          path: '/b/2.flac',
          mtimeMs: 0,
          title: 'B',
          artist: 'X feat. Y',
          album: 'Album',
        ),
        const Track(
          path: '/b/3.flac',
          mtimeMs: 0,
          title: 'C',
          artist: 'X ft. Z',
          album: 'Album',
        ),
        const Track(
          path: '/b/4.flac',
          mtimeMs: 0,
          title: 'D',
          artist: 'X featuring Q',
          album: 'Album',
        ),
        const Track(
          path: '/b/5.flac',
          mtimeMs: 0,
          title: 'E',
          artist: 'X (with Y)',
          album: 'Album',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1));
      expect(out.single.artist, 'X');
      expect(out.single.tracks, hasLength(5));
    });

    test('"X & Y" and "X, Y" do NOT strip', () {
      final tracks = <Track>[
        const Track(
          path: '/c/1.flac',
          mtimeMs: 0,
          title: 'A',
          artist: 'X & Y',
          album: 'Collab',
        ),
        const Track(
          path: '/c/2.flac',
          mtimeMs: 0,
          title: 'B',
          artist: 'X, Y',
          album: 'Collab',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      // These two artists do NOT normalise to the same key, so they
      // produce two separate album groups under the same album title.
      expect(out, hasLength(2));
    });

    test('case-insensitive markers: FEAT., Feat., feat.', () {
      final tracks = <Track>[
        const Track(
          path: '/d/1.flac',
          mtimeMs: 0,
          artist: 'X FEAT. Y',
          album: 'A',
        ),
        const Track(
          path: '/d/2.flac',
          mtimeMs: 0,
          artist: 'X Feat. Y',
          album: 'A',
        ),
        const Track(
          path: '/d/3.flac',
          mtimeMs: 0,
          artist: 'X feat. Y',
          album: 'A',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1));
      expect(out.single.artist, 'X');
    });

    test('strips at the FIRST marker for chained collaborators', () {
      final tracks = <Track>[
        const Track(
          path: '/e/1.flac',
          mtimeMs: 0,
          artist: 'X feat. Y feat. Z',
          album: 'Triplet',
        ),
        const Track(
          path: '/e/2.flac',
          mtimeMs: 0,
          artist: 'X',
          album: 'Triplet',
        ),
      ];
      final out = indexAlbums(tracks, const {}, const {});
      expect(out, hasLength(1));
      expect(out.single.artist, 'X');
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
  });
}
