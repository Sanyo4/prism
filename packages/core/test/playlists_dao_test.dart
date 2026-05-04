import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('PlaylistsDao', () {
    test('round-trip insertGenerated → listAll → getById', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.playlists;

      final id = await dao.insertGenerated(
        title: 'Rainy Sunday',
        trackPaths: const ['/a.flac', '/b.flac', '/c.flac'],
        blurb: 'A mellow morning soundtrack',
        prompt: 'rainy sunday jazz',
      );
      expect(id, greaterThan(0));

      final all = await dao.listAll();
      expect(all, hasLength(1));
      expect(all.first.title, 'Rainy Sunday');
      expect(all.first.blurb, 'A mellow morning soundtrack');
      expect(all.first.prompt, 'rainy sunday jazz');
      expect(all.first.trackPaths,
          orderedEquals(['/a.flac', '/b.flac', '/c.flac']));

      final byId = await dao.getById(id);
      expect(byId, isNotNull);
      expect(byId!.id, id);
    });

    test('listAll returns newest first', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.playlists;

      await dao.insertGenerated(
        title: 'First',
        trackPaths: const ['/1.flac'],
      );
      // Tiny delay so created_at differs.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await dao.insertGenerated(
        title: 'Second',
        trackPaths: const ['/2.flac'],
      );

      final all = await dao.listAll();
      expect(all, hasLength(2));
      expect(all.first.title, 'Second',
          reason: 'newest first by created_at');
    });

    test('deleteById cascades to playlist_tracks', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.playlists;

      final id = await dao.insertGenerated(
        title: 'Doomed',
        trackPaths: const ['/x.flac', '/y.flac'],
      );
      final beforeRows = await ctx.db.writer.rawQuery(
        'SELECT COUNT(*) AS n FROM playlist_tracks WHERE playlist_id = ?',
        [id],
      );
      expect(beforeRows.first['n'], 2);

      await dao.deleteById(id);

      final afterRows = await ctx.db.writer.rawQuery(
        'SELECT COUNT(*) AS n FROM playlist_tracks WHERE playlist_id = ?',
        [id],
      );
      expect(afterRows.first['n'], 0,
          reason: 'FK ON DELETE CASCADE should remove tracks');

      final byId = await dao.getById(id);
      expect(byId, isNull);
    });

    test('reinserting same prompt creates a new row (not deduped)', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final dao = ctx.db.playlists;

      final id1 = await dao.insertGenerated(
        title: 'Same prompt',
        trackPaths: const ['/a.flac'],
        prompt: 'rainy sunday',
      );
      final id2 = await dao.insertGenerated(
        title: 'Same prompt',
        trackPaths: const ['/b.flac'],
        prompt: 'rainy sunday',
      );
      expect(id1, isNot(id2));
      expect((await dao.listAll()), hasLength(2));
    });
  });
}
