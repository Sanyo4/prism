import 'package:prism_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('Track identity', () {
    test('tracks with the same path are equal regardless of other fields',
        () {
      const a = Track(
        path: '/music/album/01.flac',
        mtimeMs: 1000,
        title: 'Song A',
        artist: 'Artist A',
      );
      const b = Track(
        path: '/music/album/01.flac',
        mtimeMs: 2000, // different mtime
        title: 'Different title',
        artist: 'Different artist',
        album: 'Different album',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('tracks with different paths are not equal', () {
      const a = Track(path: '/music/a.flac', mtimeMs: 0);
      const b = Track(path: '/music/b.flac', mtimeMs: 0);

      expect(a, isNot(equals(b)));
    });

    test('a Track is equal to itself via identical()', () {
      const t = Track(path: '/music/x.flac', mtimeMs: 0);
      // ignore: unrelated_type_equality_checks
      expect(identical(t, t), isTrue);
      expect(t, equals(t));
    });

    test('re-scan dedup via Map<String, Track> uses path identity', () {
      const first = Track(path: '/music/a.flac', mtimeMs: 100, title: 'v1');
      const second = Track(path: '/music/a.flac', mtimeMs: 200, title: 'v2');
      final byPath = <String, Track>{};
      byPath.putIfAbsent(first.path, () => first);
      byPath.putIfAbsent(second.path, () => second);
      expect(byPath, hasLength(1));
      expect(byPath[first.path]!.title, equals('v1'));
    });
  });

  group('kSupportedExtensions', () {
    test('covers the slice-1 target formats in lowercase', () {
      expect(
        kSupportedExtensions,
        containsAll(<String>[
          '.flac',
          '.mp3',
          '.m4a',
          '.ogg',
          '.opus',
          '.wav',
        ]),
      );
    });
  });
}
