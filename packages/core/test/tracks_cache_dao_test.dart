import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

Track _t({
  required String path,
  required int mtimeMs,
  String? title,
  String? artist,
  String? album,
  Duration? duration,
}) =>
    Track(
      path: path,
      mtimeMs: mtimeMs,
      title: title ?? 'Track',
      artist: artist ?? 'Artist',
      album: album,
      duration: duration,
    );

void main() {
  group('TracksCacheDao', () {
    test('round-trip upsert → readAll', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      await dao.upsert(_t(
        path: '/a.flac',
        mtimeMs: 1000,
        title: 'A',
        album: 'Album',
        duration: const Duration(seconds: 180),
      ));
      await dao.upsert(_t(
        path: '/b.flac',
        mtimeMs: 2000,
        title: 'B',
        album: 'Album',
      ));

      final tracks = await dao.readAll();
      expect(tracks, hasLength(2));
      final byPath = {for (final t in tracks) t.path: t};
      expect(byPath['/a.flac']!.title, 'A');
      expect(byPath['/a.flac']!.duration, const Duration(seconds: 180));
      expect(byPath['/b.flac']!.title, 'B');
      expect(byPath['/b.flac']!.duration, isNull);
    });

    test('mtime-keyed updates: same path + new mtime → row replaced', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      await dao.upsert(_t(
        path: '/a.flac',
        mtimeMs: 1000,
        title: 'Old Title',
      ));
      // Re-upsert with a newer mtime + different title.
      await dao.upsert(_t(
        path: '/a.flac',
        mtimeMs: 2000,
        title: 'New Title',
      ));

      final tracks = await dao.readAll();
      expect(tracks, hasLength(1),
          reason: 'PRIMARY KEY (path) makes the second upsert replace the first');
      expect(tracks.first.title, 'New Title');
      expect(tracks.first.mtimeMs, 2000);
    });

    test('readPathMtimes returns the keyed diff map', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      await dao.upsertAll([
        _t(path: '/a.flac', mtimeMs: 1000),
        _t(path: '/b.flac', mtimeMs: 2000),
        _t(path: '/c.flac', mtimeMs: 3000),
      ]);

      final mtimes = await dao.readPathMtimes();
      expect(mtimes, hasLength(3));
      expect(mtimes['/a.flac'], 1000);
      expect(mtimes['/b.flac'], 2000);
      expect(mtimes['/c.flac'], 3000);
    });

    test('deletePathsNotIn removes stale rows + leaves live ones', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      await dao.upsertAll([
        _t(path: '/keep1.flac', mtimeMs: 1000),
        _t(path: '/keep2.flac', mtimeMs: 2000),
        _t(path: '/stale.flac', mtimeMs: 3000),
      ]);

      final removed = await dao.deletePathsNotIn(
        const {'/keep1.flac', '/keep2.flac'},
      );
      expect(removed, 1);
      final tracks = await dao.readAll();
      expect(tracks, hasLength(2));
      expect(tracks.map((t) => t.path).toSet(),
          equals({'/keep1.flac', '/keep2.flac'}));
    });

    test('deletePathsNotIn with empty live set blows the cache away', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      await dao.upsertAll([
        _t(path: '/a.flac', mtimeMs: 1000),
        _t(path: '/b.flac', mtimeMs: 2000),
      ]);

      final removed = await dao.deletePathsNotIn(const <String>{});
      expect(removed, 2);
      expect(await dao.readAll(), isEmpty);
    });

    test('upsert with mtimeMs=0 throws ArgumentError', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.tracksCache;

      expect(
        () => dao.upsert(_t(path: '/zero.flac', mtimeMs: 0)),
        throwsArgumentError,
      );
    });
  });
}
