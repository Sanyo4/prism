import 'package:prism_metadata/metadata.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Database db;
  late MetadataDao dao;
  // Pinned clock so TTL math is reproducible.
  DateTime pinned = DateTime.utc(2026, 1, 1);

  setUp(() async {
    db = await MetadataDb.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    pinned = DateTime.utc(2026, 1, 1);
    dao = MetadataDao(db, now: () => pinned);
  });

  tearDown(() async {
    await db.close();
  });

  test('cache round-trip honours TTL (unexpired ⇒ hit)', () async {
    await dao.upsertCache(
      kind: 'release',
      mbid: 'rel-1',
      payload: '{"a":1}',
      ttl: CacheTtl.oneYear,
    );

    final hit = await dao.readCache('release', 'rel-1');
    expect(hit, isNotNull);
    expect(hit!.payload, '{"a":1}');
    expect(hit.fetchedAt, pinned.millisecondsSinceEpoch);
    expect(hit.expiresAt, pinned.add(CacheTtl.oneYear).millisecondsSinceEpoch);
  });

  test('expired cache rows read as absent (treated as cache miss)', () async {
    await dao.upsertCache(
      kind: 'lastfm_artist',
      mbid: 'art-1',
      payload: '{}',
      ttl: const Duration(milliseconds: 5),
    );
    // Advance the clock past the TTL.
    pinned = pinned.add(const Duration(seconds: 1));
    expect(await dao.readCache('lastfm_artist', 'art-1'), isNull);
  });

  test('upsertCache replaces on (kind, mbid) collision', () async {
    await dao.upsertCache(
        kind: 'caa', mbid: 'rel-1', payload: '{}', ttl: CacheTtl.oneYear);
    await dao.upsertCache(
        kind: 'caa',
        mbid: 'rel-1',
        payload: '{"updated":true}',
        ttl: CacheTtl.oneYear);
    final hit = await dao.readCache('caa', 'rel-1');
    expect(hit!.payload, '{"updated":true}');
  });

  test('track_meta round-trip preserves null mbids and attempt count', () async {
    await dao.upsertTrackMeta(
      path: '/music/a.flac',
      recordingMbid: null,
      releaseMbid: null,
      artistMbid: null,
      patchedAt: 0, // tried, got nothing
      attemptCount: 1,
      lastError: 'offline',
    );

    final row = await dao.readTrackMeta('/music/a.flac');
    expect(row, isNotNull);
    expect(row!.path, '/music/a.flac');
    expect(row.recordingMbid, isNull);
    expect(row.releaseMbid, isNull);
    expect(row.patchedAt, 0);
    expect(row.attemptCount, 1);
    expect(row.lastError, 'offline');
  });

  test('clearAll wipes both tables in one transaction', () async {
    await dao.upsertCache(
        kind: 'release', mbid: 'r1', payload: '{}', ttl: CacheTtl.oneYear);
    await dao.upsertTrackMeta(
        path: '/p',
        patchedAt: pinned.millisecondsSinceEpoch,
        attemptCount: 1);
    await dao.clearAll();

    expect(await dao.readCache('release', 'r1'), isNull);
    expect(await dao.readTrackMeta('/p'), isNull);
  });

  test('schema includes the indices documented in §7', () async {
    final indices = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'metadata_cache_%' OR name LIKE 'track_meta_%'",
    );
    final names = indices.map((r) => r['name'] as String).toSet();
    expect(names, contains('metadata_cache_expires'));
    expect(names, contains('track_meta_release'));
    expect(names, contains('track_meta_artist'));
  });
}
