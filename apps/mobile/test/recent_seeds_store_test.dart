import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/radio/recent_seeds_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Slice 5 §11 item 11 + §12 — "Home Radio card LRU: 4 seeds in →
/// exactly 3 entries in shared prefs." Verified end-to-end against the
/// in-memory `SharedPreferencesAsync` mock that flutter_test ships.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RecentSeedsStore', () {
    test('round-trips one entry through SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RecentSeedsStore(prefs: prefs);
      final entry = RecentSeedEntry(
        kind: 'track',
        ref: '42',
        label: 'Chrome Pastoral',
        lastUsedAt: DateTime.utc(2026, 1, 1),
      );

      final updated = await store.upsert(entry);
      expect(updated.length, equals(1));
      expect(updated.first, equals(entry));

      // Re-load from a fresh instance to prove persistence.
      final reread = RecentSeedsStore(prefs: prefs).load();
      expect(reread.length, equals(1));
      expect(reread.first.kind, equals('track'));
      expect(reread.first.ref, equals('42'));
      expect(reread.first.label, equals('Chrome Pastoral'));
      expect(reread.first.lastUsedAt, equals(DateTime.utc(2026, 1, 1)));
    });

    test('caps at 3, oldest evicted on the 4th insert', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RecentSeedsStore(prefs: prefs);

      for (var i = 1; i <= 4; i++) {
        await store.upsert(RecentSeedEntry(
          kind: 'track',
          ref: '$i',
          label: 'Track $i',
          lastUsedAt: DateTime.utc(2026, 1, i),
        ));
      }

      final list = store.load();
      expect(list.length, equals(3),
          reason: '4 inserts must cap at 3 entries (slice 5 §11 item 11)');
      // Newest first; track 1 was the LRU and got evicted.
      expect(list.map((e) => e.ref).toList(), equals(['4', '3', '2']));
    });

    test('re-inserting an existing (kind, ref) bumps it to head '
        'without evicting others', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RecentSeedsStore(prefs: prefs);

      final a = RecentSeedEntry(
        kind: 'track',
        ref: 'A',
        label: 'A',
        lastUsedAt: DateTime.utc(2026, 1, 1),
      );
      final b = RecentSeedEntry(
        kind: 'album',
        ref: 'B',
        label: 'B',
        lastUsedAt: DateTime.utc(2026, 1, 2),
      );
      final c = RecentSeedEntry(
        kind: 'artist',
        ref: 'C',
        label: 'C',
        lastUsedAt: DateTime.utc(2026, 1, 3),
      );
      await store.upsert(a);
      await store.upsert(b);
      await store.upsert(c);

      // Re-insert A with a fresh timestamp; it should jump to head and
      // the list should still hold all three.
      final aRefreshed = RecentSeedEntry(
        kind: 'track',
        ref: 'A',
        label: 'A',
        lastUsedAt: DateTime.utc(2026, 1, 4),
      );
      await store.upsert(aRefreshed);

      final list = store.load();
      expect(list.length, equals(3));
      expect(list.first.ref, equals('A'));
      expect(list.map((e) => e.ref).toSet(), equals({'A', 'B', 'C'}));
    });

    test('handles a malformed JSON blob by returning empty', () async {
      final prefs = await SharedPreferences.getInstance();
      // Corrupt the stored value directly.
      await prefs.setString('prism.radio.recent_seeds', 'not valid json {{');
      final store = RecentSeedsStore(prefs: prefs);
      expect(store.load(), isEmpty);
    });

    test('different (kind, ref) pairs are distinct entries', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RecentSeedsStore(prefs: prefs);
      // Same `ref` but different `kind` — should not collapse.
      await store.upsert(RecentSeedEntry(
        kind: 'track',
        ref: 'X',
        label: 'X-track',
        lastUsedAt: DateTime.utc(2026, 1, 1),
      ));
      await store.upsert(RecentSeedEntry(
        kind: 'album',
        ref: 'X',
        label: 'X-album',
        lastUsedAt: DateTime.utc(2026, 1, 2),
      ));
      final list = store.load();
      expect(list.length, equals(2));
      expect(
        list.map((e) => '${e.kind}:${e.ref}').toSet(),
        equals({'album:X', 'track:X'}),
      );
    });
  });
}
