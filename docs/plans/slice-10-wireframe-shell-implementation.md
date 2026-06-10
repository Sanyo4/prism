# Slice 10 — Wireframe-Aligned Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close five wireframe-alignment follow-ups from slice 9 — lift retired Random/Vibe surfaces back into the four-tab shell, make NowPlaying radio-aware, fix the feat./ALBUMARTIST album-grouping bug, and wire up Library sort + filter — without disturbing slice-4 mood SQL, slice-5 RadioSession state machine, slice-7 theme tokens, or the locked `MoodChip` enum order.

**Architecture:** Pure-Dart foundations land first (`MoodQuery.chipExpression` extraction, `averageEmbeddings` helper in `radio_engine.dart`, new `ClusterSeed` SeedRef subclass, new `VibeShuffleQuery` in `packages/core`). Then mobile widget refactors that depend on those foundations (`MoodChipController` lift to multi-select, `_normalizeArtist` two-pass `indexAlbums`, `SongsShuffleTab`). Then UI integrations (Discover grids on Home, glass-pill restyle of `RadioBadge`/`SteerChipBar`, `startFromCluster`, end-of-playlist sheet). Then Library polish (`LibraryViewPrefs` Riverpod provider + `LibraryFilterSheet`). Cleanup (deletions, route drops, gear-icon test rewrite) lands last.

**Tech Stack:** Flutter 3.x, Riverpod 3, sqflite + sqflite_common_ffi, sqlite_vec0, just_audio, audio_service, shared_preferences. Pure-Dart packages (`prism_core`, `prism_playlist_engine`) tested via `dart test`; Flutter packages via `flutter test`.

---

## Sequencing Map

The work fans out across 6 spec sub-sections (§2.1–§2.6). The 22 tasks below are sequenced so every task's dependencies land first:

```
Phase A — Pure-Dart foundations (lowest risk; dart test only)
  Task 1   chipExpression extraction          (unblocks Task 4, 7)
  Task 2   averageEmbeddings + ClusterSeed    (unblocks Task 11, 12)
  Task 3   recencyFactor helper               (unblocks Task 4)
  Task 4   VibeShuffleQuery                   (unblocks Task 7)

Phase B — Mobile data + chip refactors
  Task 5   MoodChipController lift            (unblocks Task 7)
  Task 6   indexAlbums two-pass + _normalizeArtist

Phase C — Songs surface + Discover Home
  Task 7   SongsShuffleTab                    (replaces _SongsTab body)
  Task 8   DiscoverGrids on HomeScreen        (retires RandomTab)

Phase D — Radio integrations
  Task 9   RadioBadge / SteerChipBar restyle + parent-layout guard
  Task 10  startFromCluster on RadioSessionNotifier
  Task 11  EndOfPlaylistSheet + AI-Compose end-of-queue observer
  Task 12  Infinite toggle + lookahead trigger from Songs tab

Phase E — Library sort + filter
  Task 13  LibraryViewPrefs provider + value class
  Task 14  genreOptionsProvider
  Task 15  LibraryFilterSheet
  Task 16  Library header buttons + sort callbacks + filter wiring
  Task 17  Pre-warm libraryViewPrefsProvider in main.dart

Phase F — Cleanup, route drops, test rewrite
  Task 18  Retire VibeBrowseScreen + tempo_band_chips owners
  Task 19  Retire RadioHomeCard + RadioSeedHeader + queue_screen edit
  Task 20  Drop /random and /vibe routes from app.dart
  Task 21  Rewrite widget_test.dart gear-icon walk
  Task 22  Final analyze + full-test sweep
```

## Verification commands per phase

Run from repo root unless otherwise noted:

| Phase | Commands |
|-------|----------|
| A     | `cd packages/core && dart test`, `cd packages/playlist_engine && dart test` |
| B     | `cd packages/core && dart test`, `cd apps/mobile && flutter test` |
| C     | `cd apps/mobile && flutter test`, `flutter analyze` |
| D     | `cd packages/playlist_engine && dart test`, `cd apps/mobile && flutter test`, `flutter analyze` |
| E     | `cd apps/mobile && flutter test`, `flutter analyze` |
| F     | `flutter analyze`, `cd packages/core && dart test`, `cd packages/playlist_engine && dart test`, `cd apps/mobile && flutter test` |

The final task (Task 22) runs everything end-to-end.

## Locked invariants (re-stated for every task)

- Slice-4 mood SQL fragments stay byte-identical. `MoodQuery.chipExpression(MoodChip)` is a *pure extraction* — every test in `packages/core/test/mood_query_test.dart` must continue to pass without modification.
- Slice-5 `RadioSession` state machine (the `tick`, `withChipToggled`, `withChipCleared`, `withSkipped`, `copyAfterPick` transitions) stays byte-identical. Adding `ClusterSeed` to the `sealed class SeedRef` family is *additive* and does not touch the state machine.
- Slice-7 theme tokens (`SpaceTokens`, `TypographyScale`, `AlbumPalette`, `AuroraBackground`, `Glass`) are consumed only — not modified.
- `MoodChip` enum order (`happy / sad / chill / energetic / focus`) is preserved; `MoodChipRow.visualOrder` keeps the same five-element list. `mood_chip_row_test.dart` (slice 4) must continue to pass after Task 5.

---

## Phase A — Pure-Dart foundations

### Task 1: Extract `MoodQuery.chipExpression` (public helper)

Pulls the per-chip composite SQL fragments out of the private `_querySpec` switch into a public `static String chipExpression(MoodChip)` so `VibeShuffleQuery` (Task 4) can reuse them without duplicating. Behaviour byte-identical — `_querySpec` keeps the `confidenceExpr` field, but it now reads from `chipExpression`.

**Files:**
- Modify: `packages/core/lib/src/db/mood_query.dart`
- Test: `packages/core/test/mood_query_test.dart` (existing tests must still pass)
- New test: append a group to `packages/core/test/mood_query_test.dart` asserting byte-identical output of `chipExpression`

- [ ] **Step 1: Add the failing assertion test**

Append this group to `packages/core/test/mood_query_test.dart`:

```dart
  group('MoodQuery.chipExpression', () {
    test('happy returns mood_happy', () {
      expect(MoodQuery.chipExpression(MoodChip.happy), 'mood_happy');
    });

    test('sad returns mood_sad', () {
      expect(MoodQuery.chipExpression(MoodChip.sad), 'mood_sad');
    });

    test('chill applies bpm < 110 weighting', () {
      expect(
        MoodQuery.chipExpression(MoodChip.chill),
        'mood_relaxed * CASE WHEN bpm < 110 THEN 1.0 ELSE 0.5 END',
      );
    });

    test('energetic uses MAX(party, danceability) and bpm > 110 weighting', () {
      expect(
        MoodQuery.chipExpression(MoodChip.energetic),
        'MAX(COALESCE(mood_party, 0.0), COALESCE(danceability, 0.0)) '
        ' * CASE WHEN bpm > 110 THEN 1.0 ELSE 0.5 END',
      );
    });

    test('focus penalises aggressive + party', () {
      expect(
        MoodQuery.chipExpression(MoodChip.focus),
        'voice_instrumental '
        ' * (1.0 - COALESCE(mood_aggressive, 0.0)) '
        ' * (1.0 - COALESCE(mood_party, 0.0))',
      );
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/core && dart test test/mood_query_test.dart`
Expected: FAIL with `MoodQuery.chipExpression` undefined.

- [ ] **Step 3: Implement `chipExpression` and have `_querySpec` call it**

Edit `packages/core/lib/src/db/mood_query.dart`. Inside `class MoodQuery`, before the `_querySpec` method, add:

```dart
  /// Public access to the per-chip composite SQL fragment used to
  /// compute the chip's confidence score. Slice 10 §5 invariant: the
  /// returned strings are byte-identical to the slice-4 SQL — `_querySpec`
  /// reads from this method, and `VibeShuffleQuery` reuses the same
  /// fragments to keep the chip→column mapping the single source of truth.
  static String chipExpression(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return 'mood_happy';
      case MoodChip.sad:
        return 'mood_sad';
      case MoodChip.chill:
        return 'mood_relaxed * CASE WHEN bpm < 110 THEN 1.0 ELSE 0.5 END';
      case MoodChip.energetic:
        return 'MAX(COALESCE(mood_party, 0.0), COALESCE(danceability, 0.0)) '
            ' * CASE WHEN bpm > 110 THEN 1.0 ELSE 0.5 END';
      case MoodChip.focus:
        return 'voice_instrumental '
            ' * (1.0 - COALESCE(mood_aggressive, 0.0)) '
            ' * (1.0 - COALESCE(mood_party, 0.0))';
    }
  }
```

Then change `_querySpec`'s `confidenceExpr` lines to call `chipExpression(chip)`:

```dart
  static _ChipSpec _querySpec(MoodChip chip) {
    final expr = chipExpression(chip);
    switch (chip) {
      case MoodChip.happy:
        return _ChipSpec(
          confidenceExpr: expr,
          filter: 'mood_happy IS NOT NULL',
          params: const [],
        );
      case MoodChip.sad:
        return _ChipSpec(
          confidenceExpr: expr,
          filter: 'mood_sad IS NOT NULL',
          params: const [],
        );
      case MoodChip.chill:
        return _ChipSpec(
          confidenceExpr: expr,
          filter: 'mood_relaxed IS NOT NULL',
          params: const [],
        );
      case MoodChip.energetic:
        return _ChipSpec(
          confidenceExpr: expr,
          filter: '(mood_party IS NOT NULL OR danceability IS NOT NULL)',
          params: const [],
        );
      case MoodChip.focus:
        return _ChipSpec(
          confidenceExpr: expr,
          filter: 'voice_instrumental IS NOT NULL',
          params: const [],
        );
    }
  }
```

- [ ] **Step 4: Run all MoodQuery tests to verify byte-identical behaviour**

Run: `cd packages/core && dart test test/mood_query_test.dart`
Expected: All tests pass — both the new `chipExpression` group AND the pre-existing per-chip tests.

- [ ] **Step 5: Commit**

```bash
git add packages/core/lib/src/db/mood_query.dart packages/core/test/mood_query_test.dart
git commit -m "core: extract MoodQuery.chipExpression public helper

Byte-identical SQL for the slice-4 chip→column mapping, exposed so
VibeShuffleQuery can reuse it. _querySpec now calls chipExpression().
Existing slice-4 mood_query_test.dart suite continues to pass."
```

---

### Task 2: `averageEmbeddings` + `ClusterSeed` in `prism_playlist_engine`

Adds the pure-Dart helper that averages a list of 1280-dim embeddings into one L2-normalised vector (returning `null` on empty input), plus a new `ClusterSeed` subclass of the existing `sealed class SeedRef`. `startFromCluster` (Task 10) will consume both.

**Files:**
- Modify: `packages/playlist_engine/lib/radio_engine.dart` (add `averageEmbeddings` static method)
- Modify: `packages/playlist_engine/lib/radio_session.dart` (add `ClusterSeed`)
- Test: `packages/playlist_engine/test/radio_engine_test.dart` (append `averageEmbeddings` group)

- [ ] **Step 1: Write failing tests for `averageEmbeddings`**

Append this group to the bottom of `packages/playlist_engine/test/radio_engine_test.dart`'s `main()`:

```dart
  group('RadioEngine.averageEmbeddings', () {
    test('returns null for empty list', () {
      expect(RadioEngine.averageEmbeddings(const []), isNull);
    });

    test('single vector echoes its L2-normalised form', () {
      final v = Float32List.fromList(List<double>.filled(1280, 0.0));
      v[0] = 3.0;
      v[1] = 4.0; // L2 norm = 5
      final out = RadioEngine.averageEmbeddings([v]);
      expect(out, isNotNull);
      expect(out!.length, 1280);
      expect(out[0], closeTo(0.6, 1e-6));
      expect(out[1], closeTo(0.8, 1e-6));
      var sumSq = 0.0;
      for (final x in out) {
        sumSq += x * x;
      }
      expect(sumSq, closeTo(1.0, 1e-3));
    });

    test('two-vector mean is element-wise then L2-normalised', () {
      final a = Float32List(1280);
      a[0] = 2.0;
      final b = Float32List(1280);
      b[0] = 4.0;
      final out = RadioEngine.averageEmbeddings([a, b]);
      // Mean[0] = 3.0; norm = 3 → out[0] = 1.0.
      expect(out, isNotNull);
      expect(out![0], closeTo(1.0, 1e-6));
      for (var i = 1; i < 1280; i++) {
        expect(out[i], closeTo(0.0, 1e-6));
      }
    });

    test('zero-mean vector returns the zero vector untouched', () {
      final z = Float32List(1280);
      final out = RadioEngine.averageEmbeddings([z, z]);
      expect(out, isNotNull);
      for (final x in out!) {
        expect(x, 0.0);
      }
    });

    test('rejects vectors of unexpected length', () {
      final wrong = Float32List(1024);
      expect(
        () => RadioEngine.averageEmbeddings([wrong]),
        throwsArgumentError,
      );
    });
  });
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cd packages/playlist_engine && dart test test/radio_engine_test.dart`
Expected: FAIL — `averageEmbeddings` undefined.

- [ ] **Step 3: Implement `averageEmbeddings`**

Edit `packages/playlist_engine/lib/radio_engine.dart`. Inside `class RadioEngine`, after the `_l2Normalize` static method, add:

```dart
  /// Element-wise average of [vectors], then L2-normalised. Returns
  /// `null` on empty input. Used by `RadioSessionNotifier.startFromCluster`
  /// (slice 10) to seed a session from a list of tracks treated as a
  /// synthetic cluster — matches the format `meanEmbeddingForAlbum`
  /// already returns.
  ///
  /// All input vectors must be 1280-dim; mismatched lengths throw
  /// `ArgumentError`.
  static Float32List? averageEmbeddings(List<Float32List> vectors) {
    if (vectors.isEmpty) return null;
    const dim = 1280;
    for (final v in vectors) {
      if (v.length != dim) {
        throw ArgumentError(
          'averageEmbeddings: expected length $dim, got ${v.length}',
        );
      }
    }
    final acc = Float32List(dim);
    for (final v in vectors) {
      for (var i = 0; i < dim; i++) {
        acc[i] += v[i];
      }
    }
    final n = vectors.length;
    for (var i = 0; i < dim; i++) {
      acc[i] /= n;
    }
    return _l2Normalize(acc);
  }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd packages/playlist_engine && dart test test/radio_engine_test.dart`
Expected: All tests pass, including the existing slice-5 `RadioEngine.from*` and `RadioEngine.next` groups.

- [ ] **Step 5: Add `ClusterSeed` to the SeedRef sealed family**

Edit `packages/playlist_engine/lib/radio_session.dart`. After the existing `ArtistSeed` final class (around line 76), append:

```dart
/// Seed = a synthetic cluster of tracks (slice 10 §2.3). The session's
/// `seedEmbedding` is the L2-normalised mean of the cluster's per-track
/// embeddings. `trackIds` carries the constituent ids so callers can
/// re-render the cluster's tracks (e.g. an end-of-playlist preview row).
/// `steeringHint` is an optional free-form label inferred from the
/// originating prompt — surfaced verbatim in the badge label.
final class ClusterSeed extends SeedRef {
  final List<int> trackIds;
  final String? steeringHint;
  @override
  final String label;
  const ClusterSeed({
    required this.trackIds,
    required this.label,
    this.steeringHint,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ClusterSeed &&
          other.label == label &&
          other.steeringHint == steeringHint &&
          _listEquals(other.trackIds, trackIds));

  @override
  int get hashCode =>
      Object.hash(label, steeringHint, Object.hashAll(trackIds));
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return a.length == b.length;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
```

- [ ] **Step 6: Add a sanity test for `ClusterSeed`**

Append a small group to `packages/playlist_engine/test/radio_engine_test.dart`:

```dart
  group('ClusterSeed', () {
    test('label flows through to SeedRef.label', () {
      const seed = ClusterSeed(
        trackIds: [1, 2, 3],
        label: 'Rainy Sunday jazz',
        steeringHint: 'rainy_sunday',
      );
      expect((seed as SeedRef).label, 'Rainy Sunday jazz');
      expect(seed.steeringHint, 'rainy_sunday');
    });

    test('equality compares label, hint, and track id list', () {
      const a = ClusterSeed(trackIds: [1, 2], label: 'x');
      const b = ClusterSeed(trackIds: [1, 2], label: 'x');
      const c = ClusterSeed(trackIds: [1, 3], label: 'x');
      expect(a, b);
      expect(a, isNot(c));
    });
  });
```

- [ ] **Step 7: Run the full radio engine test file**

Run: `cd packages/playlist_engine && dart test test/radio_engine_test.dart`
Expected: All tests pass — including pre-existing slice-5 tests, the new `averageEmbeddings` group, and the new `ClusterSeed` group.

- [ ] **Step 8: Commit**

```bash
git add packages/playlist_engine/lib/radio_engine.dart packages/playlist_engine/lib/radio_session.dart packages/playlist_engine/test/radio_engine_test.dart
git commit -m "playlist_engine: add averageEmbeddings + ClusterSeed

Adds RadioEngine.averageEmbeddings (List<Float32List>) -> Float32List?
that returns the L2-normalised element-wise mean, matching the format
PlaylistRepo.meanEmbeddingForAlbum already produces. Adds ClusterSeed
subclass to the sealed SeedRef family for slice-10 startFromCluster
(notifier-level entry point landing in a later commit). Slice-5
RadioSession state machine (tick/withChipToggled/copyAfterPick/
withSkipped) is byte-identical."
```

---

### Task 3: `recencyFactor` shared helper

Lifts MoodQuery's existing recency formula (`0.5 + 0.5 * exp(-days_since_added / 365)`) into a public top-level helper so `VibeShuffleQuery` (Task 4) can apply the same Dart-side recency to its deck without re-deriving the constant. MoodQuery's behaviour stays byte-identical: its existing `_rankScore` calls the new helper instead of inlining the math.

**Files:**
- Modify: `packages/core/lib/src/db/mood_query.dart`
- Test: append a group to `packages/core/test/mood_query_test.dart`

- [ ] **Step 1: Write the failing test**

Append to `packages/core/test/mood_query_test.dart`:

```dart
  group('recencyFactor', () {
    test('returns 1.0 for now (zero days elapsed)', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        recencyFactor(addedAtMs: now, nowMs: now),
        closeTo(1.0, 1e-9),
      );
    });

    test('decays exponentially with age', () {
      final now = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final yearAgo = now - 365 * Duration.millisecondsPerDay;
      // 0.5 + 0.5 * exp(-1) ≈ 0.6839
      expect(
        recencyFactor(addedAtMs: yearAgo, nowMs: now),
        closeTo(0.5 + 0.5 * 0.36787944117, 1e-6),
      );
    });

    test('floor of 0.5 as days → ∞', () {
      final now = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final ancient = now - 100 * 365 * Duration.millisecondsPerDay;
      expect(
        recencyFactor(addedAtMs: ancient, nowMs: now),
        closeTo(0.5, 1e-3),
      );
    });
  });
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd packages/core && dart test test/mood_query_test.dart -N recencyFactor`
Expected: FAIL — `recencyFactor` undefined.

- [ ] **Step 3: Add the helper as a top-level function**

Edit `packages/core/lib/src/db/mood_query.dart`. After the existing `import 'cache_db.dart';` (around line 3), but BEFORE `enum MoodChip { ... }`, add:

```dart
/// Slice-4 recency factor, lifted into a top-level helper so slice 10's
/// `VibeShuffleQuery` can reuse the same falloff as `MoodQuery`. Pure
/// math: `0.5 + 0.5 * exp(-days_since_added / 365)`. Result is always
/// in `[0.5, 1.0]` — zero-day-old tracks score `1.0`; very old tracks
/// asymptote to `0.5`.
double recencyFactor({required int addedAtMs, required int nowMs}) {
  final days = (nowMs - addedAtMs) / Duration.millisecondsPerDay;
  return 0.5 + 0.5 * math.exp(-days / 365);
}
```

Then change `MoodQuery._rankScore` to call `recencyFactor`:

```dart
  static double _rankScore({
    required double confidence,
    required int playCount,
    required int addedAtMs,
    required int nowMs,
  }) {
    final recency = recencyFactor(addedAtMs: addedAtMs, nowMs: nowMs);
    final play = math.log(1 + playCount);
    // … (rest of doc comment unchanged) …
    return confidence * (1 + play) * recency;
  }
```

The numeric output of `_rankScore` is byte-identical because the recency component lifted out is the exact same expression.

- [ ] **Step 4: Run the full mood_query test file**

Run: `cd packages/core && dart test test/mood_query_test.dart`
Expected: All tests pass — both the pre-existing per-chip ordering tests AND the new `recencyFactor` group AND the `chipExpression` group from Task 1.

- [ ] **Step 5: Commit**

```bash
git add packages/core/lib/src/db/mood_query.dart packages/core/test/mood_query_test.dart
git commit -m "core: lift recency formula into top-level recencyFactor helper

Slice-10 VibeShuffleQuery (lands in a later commit) reuses the same
0.5 + 0.5 * exp(-days/365) recency that MoodQuery already applies. No
change to MoodQuery._rankScore output — the lifted expression is
byte-identical."
```

---

### Task 4: `VibeShuffleQuery` (new SQL builder)

Pure-Dart class that produces the iPod-shuffle deck for the Songs tab. Three modes (true-shuffle / 1-chip filter / 2+-chip bias) match spec §2.2; tempo-band predicate ANDs in regardless of mode; result deck capped at `LIMIT 1000`. Recency applied Dart-side via `recencyFactor` (Task 3) on the bias-mode rank.

**Files:**
- Create: `packages/core/lib/src/db/vibe_shuffle_query.dart`
- Modify: `packages/core/lib/core.dart` (export the new class)
- Modify: `packages/core/lib/src/db/cache_db.dart` (add `VibeShuffleQuery get vibeShuffle`)
- Test: `packages/core/test/vibe_shuffle_query_test.dart`

- [ ] **Step 1: Write the failing test file**

Create `packages/core/test/vibe_shuffle_query_test.dart`:

```dart
import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

/// Slice 10 §6: covers the three steering modes (true-shuffle /
/// filter / bias) plus the tempo-band intersection.
///
/// Fixture: 6 tracks across three chip strengths × three tempo bands.
/// Numeric checks use chipExpression's known output so a re-derivation
/// of the formulas would also need to update this file.
void main() {
  group('VibeShuffleQuery', () {
    test('zero chips, true-shuffle off → returns up to LIMIT random rows', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const <MoodChip>{},
        band: null,
        trueShuffle: false,
      );
      expect(result, hasLength(6));
    });

    test('one chip filters by chipExpression > 0.5', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill},
        band: null,
        trueShuffle: false,
      );
      // Two chill rows in the fixture (calm + relaxed); one is below
      // the 0.5 floor after the bpm-penalty multiplier.
      expect(result, isNotEmpty);
      for (final row in result) {
        expect(row.score, greaterThan(0.5));
      }
    });

    test('two chips additively combine via Σ chipExpression > 0', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill, MoodChip.focus},
        band: null,
        trueShuffle: false,
      );
      // First row should have the highest combined score.
      expect(result, isNotEmpty);
      for (var i = 1; i < result.length; i++) {
        expect(
          result[i - 1].score,
          greaterThanOrEqualTo(result[i].score),
        );
      }
    });

    test('tempo band ANDs into the where clause regardless of mode', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final result = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.energetic},
        band: TempoBand.hot,
        trueShuffle: false,
      );
      for (final row in result) {
        expect(row.bpm, greaterThan(120),
            reason: 'TempoBand.hot is bpm > 120');
      }
    });

    test('true-shuffle on bypasses chip filtering', () async {
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      await _seedSixTracks(ctx.db);
      final filtered = await VibeShuffleQuery(ctx.db).run(
        chips: const {MoodChip.chill},
        band: null,
        trueShuffle: true,
      );
      // True-shuffle ignores chips and returns all 6 ready rows.
      expect(filtered, hasLength(6));
    });

    test('respects LIMIT 1000 cap', () async {
      // The cap is in SQL; assert via a trivial unit on the constant.
      expect(VibeShuffleQuery.deckLimit, 1000);
    });
  });
}

Future<void> _seedSixTracks(CacheDb db) async {
  // Three chip strengths × three tempo bands. Picked so each mode test
  // has a deterministic answer.
  await insertRawTrackRow(
    db.writer, path: '/c1.flac', audioSha1: '1' * 40,
    moodRelaxed: 0.9, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.7, danceability: 0.0,
    bpm: 80.0, // calm
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/c2.flac', audioSha1: '2' * 40,
    moodRelaxed: 0.7, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.4, danceability: 0.0,
    bpm: 100.0, // mid
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/c3.flac', audioSha1: '3' * 40,
    moodRelaxed: 0.6, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.2, danceability: 0.0,
    bpm: 130.0, // hot — hits the 0.5 chill penalty (bpm > 110)
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/e1.flac', audioSha1: '4' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.85, voiceInstrumental: 0.0, danceability: 0.6,
    bpm: 140.0, // hot
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/e2.flac', audioSha1: '5' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.7, voiceInstrumental: 0.0, danceability: 0.5,
    bpm: 95.0, // mid
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
  await insertRawTrackRow(
    db.writer, path: '/f1.flac', audioSha1: '6' * 40,
    moodRelaxed: 0.0, moodHappy: 0.0, moodSad: 0.0, moodAggressive: 0.0,
    moodParty: 0.0, voiceInstrumental: 0.95, danceability: 0.0,
    bpm: 90.0, // calm
    addedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
  );
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd packages/core && dart test test/vibe_shuffle_query_test.dart`
Expected: FAIL — `VibeShuffleQuery` does not exist.

- [ ] **Step 3: Implement `VibeShuffleQuery`**

Create `packages/core/lib/src/db/vibe_shuffle_query.dart`:

```dart
import 'cache_db.dart';
import 'mood_query.dart';
import 'vibe_query.dart';

/// One row in the Songs-tab shuffle deck. Distinct from
/// [VibeTrack]/[RankedTrack] so the consumer doesn't have to disambiguate
/// score semantics — `score` here is the steering rank (chip sum × recency).
class ShuffleTrack {
  /// `tracks.id` — same engine-id slice-5 keys on.
  final int trackId;
  final String path;
  final String? title;
  final String? artist;
  final String? album;

  /// Raw chip-expression sum (or single chip's value, or 0.0 in true-
  /// shuffle / zero-chip mode). Consumers that only need playback don't
  /// need this; the Songs tab sorts by it for the visible deck.
  final double score;

  final double? bpm;

  const ShuffleTrack({
    required this.trackId,
    required this.path,
    required this.score,
    this.title,
    this.artist,
    this.album,
    this.bpm,
  });
}

/// Builds the Songs-tab shuffle deck (slice 10 §2.2). Three modes,
/// selected by chip count and the True-Shuffle override. The chip
/// expressions are reused verbatim from [MoodQuery.chipExpression]; the
/// recency factor (Dart-side, see [recencyFactor]) is applied to the
/// bias and filter rankings to mirror `MoodQuery._rankScore`.
class VibeShuffleQuery {
  VibeShuffleQuery(this._db);
  final CacheDb _db;

  /// Hard upper bound on rows returned in any mode. Matches slice-4's
  /// `LIMIT 1000` precedent — keeps the visible list and the shuffle
  /// pool bounded on libraries with tens of thousands of tracks.
  static const int deckLimit = 1000;

  /// Confidence floor in single-chip filter mode. Matches §2.2 spec:
  /// "1 chip filter: WHERE <chip.expr> > 0.5".
  static const double singleChipFloor = 0.5;

  /// Returns the deck under the chip set + tempo band. When [trueShuffle]
  /// is true, [chips] is ignored and a uniformly-random deck of
  /// `status='ready'` rows is returned.
  Future<List<ShuffleTrack>> run({
    required Set<MoodChip> chips,
    required TempoBand? band,
    required bool trueShuffle,
    DateTime? now,
  }) async {
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final whereParts = <String>["status = 'ready'"];
    if (band != null) {
      whereParts.add(_bandPredicate(band));
    }

    if (trueShuffle || chips.isEmpty) {
      final sql = '''
        SELECT id, path, title, artist, album, bpm, added_at
          FROM tracks
         WHERE ${whereParts.join(' AND ')}
         ORDER BY RANDOM()
         LIMIT $deckLimit
      ''';
      final rows = await _db.writer.rawQuery(sql);
      return [
        for (final r in rows)
          ShuffleTrack(
            trackId: r['id'] as int,
            path: r['path'] as String,
            title: r['title'] as String?,
            artist: r['artist'] as String?,
            album: r['album'] as String?,
            score: 0.0,
            bpm: (r['bpm'] as num?)?.toDouble(),
          ),
      ];
    }

    // Build the score expression: single chip = its expression; many
    // chips = additive sum. Identical chip-expression strings either way.
    final chipExprs =
        chips.map(MoodQuery.chipExpression).toList(growable: false);
    final scoreExpr = chipExprs.length == 1
        ? chipExprs.first
        : '(${chipExprs.join(' + ')})';
    if (chipExprs.length == 1) {
      whereParts.add('($scoreExpr) > $singleChipFloor');
    } else {
      whereParts.add('($scoreExpr) > 0');
    }

    final sql = '''
      SELECT id, path, title, artist, album, bpm, added_at,
             ($scoreExpr) AS score
        FROM tracks
       WHERE ${whereParts.join(' AND ')}
       ORDER BY score DESC
       LIMIT $deckLimit
    ''';
    final rows = await _db.writer.rawQuery(sql);

    // Re-rank in Dart by score × recencyFactor — same pattern as
    // MoodQuery's two-phase rank.
    final ranked = <({ShuffleTrack track, double rank})>[];
    for (final r in rows) {
      final rawScore = (r['score'] as num?)?.toDouble() ?? 0.0;
      final addedAt = (r['added_at'] as int?) ?? nowMs;
      final recency = recencyFactor(addedAtMs: addedAt, nowMs: nowMs);
      final rank = rawScore * recency;
      ranked.add((
        track: ShuffleTrack(
          trackId: r['id'] as int,
          path: r['path'] as String,
          title: r['title'] as String?,
          artist: r['artist'] as String?,
          album: r['album'] as String?,
          score: rawScore,
          bpm: (r['bpm'] as num?)?.toDouble(),
        ),
        rank: rank,
      ));
    }
    ranked.sort((a, b) => b.rank.compareTo(a.rank));
    return [for (final e in ranked) e.track];
  }

  /// Reuses `VibeQuery._bandPredicate` semantics verbatim — calm < 90,
  /// mid 90..120 inclusive, hot > 120. Boundary inclusivity is the
  /// invariant slice-4 verification matrix locks.
  static String _bandPredicate(TempoBand band) {
    switch (band) {
      case TempoBand.calm:
        return 'bpm < 90';
      case TempoBand.mid:
        return 'bpm BETWEEN 90 AND 120';
      case TempoBand.hot:
        return 'bpm > 120';
    }
  }
}
```

- [ ] **Step 4: Export it from the package barrel + add `cacheDb.vibeShuffle` getter**

Edit `packages/core/lib/core.dart`. Add after the existing `vibe_query.dart` export:

```dart
export 'src/db/vibe_shuffle_query.dart';
```

Edit `packages/core/lib/src/db/cache_db.dart`. After the `VibeQuery get vibes => VibeQuery(this);` getter, add:

```dart
  /// Slice 10 — vibe-steered shuffle deck for the Songs tab.
  VibeShuffleQuery get vibeShuffle => VibeShuffleQuery(this);
```

Add the matching import at the top of `cache_db.dart`:

```dart
import 'vibe_shuffle_query.dart';
```

- [ ] **Step 5: Run test to verify pass**

Run: `cd packages/core && dart test test/vibe_shuffle_query_test.dart`
Expected: All tests pass.

- [ ] **Step 6: Run the full core test suite to confirm no regressions**

Run: `cd packages/core && dart test`
Expected: All tests pass — including the slice-4 `mood_query_test.dart`, `vibe_query_test.dart`, etc.

- [ ] **Step 7: Commit**

```bash
git add packages/core/lib/src/db/vibe_shuffle_query.dart packages/core/lib/core.dart packages/core/lib/src/db/cache_db.dart packages/core/test/vibe_shuffle_query_test.dart
git commit -m "core: add VibeShuffleQuery for the Songs-tab shuffle deck

Three modes selected by chip count: zero/true-shuffle returns RANDOM
LIMIT 1000; one chip filters chipExpression > 0.5; two+ chips combines
additively (sum > 0). Tempo band ANDs into WHERE in every mode. Recency
factor applied Dart-side, matching MoodQuery's two-phase rank. Reuses
MoodQuery.chipExpression byte-identically (slice 10 §5 invariant)."
```

---

## Phase B — Mobile data + chip refactors

### Task 5: `MoodChipController` lift to multi-select

The current `MoodChipRow` is a stateless widget that always pushes the tapped chip to `MoodResultsScreen`. To support the Songs-tab multi-select case, lift the selection model into a `MoodChipController` value class and have the widget consume it. Two factories — `MoodChipController.single()` (used by Home, behaviour byte-identical) and `MoodChipController.multi(initial: ...)` (used by SongsShuffleTab in Task 7).

**Files:**
- Modify: `apps/mobile/lib/widgets/mood_chip_row.dart`
- Modify: `apps/mobile/lib/screens/home_screen.dart` (callsite: pass `.single()` or use the default-single shorthand)
- Test: `apps/mobile/test/mood_chip_row_test.dart` (existing single-mode test stays green; add a multi-mode test)

- [ ] **Step 1: Write the failing multi-mode test**

Append to `apps/mobile/test/mood_chip_row_test.dart` (inside the existing `group('MoodChipRow', () { … })`):

```dart
    testWidgets('multi-select toggles a chip into the controller set',
        (tester) async {
      var lastSelection = <MoodChip>{};
      final controller = MoodChipController.multi(
        initial: const <MoodChip>{},
        onChanged: (next) => lastSelection = next,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: PrismTheme.light(),
          home: Scaffold(body: MoodChipRow(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the Chill chip; the multi-select callback should fire with
      // {MoodChip.chill}.
      await tester.tap(find.text('Chill'));
      await tester.pumpAndSettle();
      expect(lastSelection, equals(<MoodChip>{MoodChip.chill}));

      // Tap Focus; callback fires with {chill, focus}.
      await tester.tap(find.text('Focus'));
      await tester.pumpAndSettle();
      expect(lastSelection, equals(<MoodChip>{MoodChip.chill, MoodChip.focus}));

      // Tap Chill again; should remove from the set.
      await tester.tap(find.text('Chill'));
      await tester.pumpAndSettle();
      expect(lastSelection, equals(<MoodChip>{MoodChip.focus}));
    });

    testWidgets('single-select default keeps slice-4 push behaviour',
        (tester) async {
      // Smoke-test: tap pushes a route. We verify the route by mounting
      // a Navigator and listening for push events.
      final pushed = <Route<dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: PrismTheme.light(),
          home: Scaffold(body: const MoodChipRow()),
          navigatorObservers: [
            _CapturingObserver(onPush: pushed.add),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Happy'));
      await tester.pumpAndSettle();
      expect(pushed, isNotEmpty,
          reason: 'single-mode tap pushes MoodResultsScreen');
    });
```

Also add this helper class at the end of the same test file (outside `main()`):

```dart
class _CapturingObserver extends NavigatorObserver {
  _CapturingObserver({required this.onPush});
  final void Function(Route<dynamic>) onPush;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onPush(route);
    super.didPush(route, previousRoute);
  }
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/mood_chip_row_test.dart`
Expected: FAIL — `MoodChipController` undefined; `MoodChipRow.controller` parameter undefined.

- [ ] **Step 3: Implement `MoodChipController` and refactor `MoodChipRow`**

Replace `apps/mobile/lib/widgets/mood_chip_row.dart`'s body with:

```dart
import 'package:flutter/material.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../screens/mood_results_screen.dart';

/// Selection model for [MoodChipRow]. Two factories:
///
/// - [MoodChipController.single] — slice-4 behaviour: a tap navigates
///   to `MoodResultsScreen` for that chip and the row never holds a
///   selection. Home consumes this.
/// - [MoodChipController.multi] — slice-10 behaviour: tap toggles the
///   chip in/out of [selected]; [onChanged] fires with the resulting
///   set. SongsShuffleTab consumes this.
///
/// Defense against the slice-1 widget tests: existing `mood_chip_row_test.dart`
/// only asserts the locked visual order and the FilterChip count, both
/// of which the refactor preserves.
class MoodChipController {
  /// Internal mode flag — `false` for slice-4 single push, `true` for
  /// slice-10 multi-select.
  final bool isMulti;

  /// Currently-selected chips (multi mode only). Always empty in single
  /// mode — single-mode taps don't accumulate state.
  final Set<MoodChip> selected;

  /// Multi-mode change callback. `null` in single mode.
  final ValueChanged<Set<MoodChip>>? onChanged;

  const MoodChipController._({
    required this.isMulti,
    required this.selected,
    required this.onChanged,
  });

  /// Slice-4 single-select: tap pushes [MoodResultsScreen]. The
  /// controller carries no selection state.
  const MoodChipController.single()
      : this._(isMulti: false, selected: const <MoodChip>{}, onChanged: null);

  /// Slice-10 multi-select: tap toggles into [initial]. [onChanged]
  /// fires with the resulting set so the parent can refresh its query.
  const MoodChipController.multi({
    required Set<MoodChip> initial,
    required ValueChanged<Set<MoodChip>> onChanged,
  }) : this._(isMulti: true, selected: initial, onChanged: onChanged);
}

/// Five Material 3 FilterChips in **locked order**: Happy / Sad / Chill
/// / Energetic / Focus. Slice-10 lift adds the multi-select mode via
/// [controller]; default is the slice-4 single-select push.
class MoodChipRow extends StatelessWidget {
  const MoodChipRow({
    super.key,
    this.controller = const MoodChipController.single(),
    this.dim = false,
  });

  /// Selection / dispatch model. Defaults to single-select for the
  /// pre-existing Home consumer.
  final MoodChipController controller;

  /// When `true`, all chips render at 50% opacity (Songs-tab
  /// True-Shuffle ON state per spec §2.2). The chips remain tappable —
  /// dimming is purely visual.
  final bool dim;

  /// Locked rendering order. Visible to widget tests so the order can
  /// be asserted without reaching into private state.
  static const List<MoodChip> visualOrder = <MoodChip>[
    MoodChip.happy,
    MoodChip.sad,
    MoodChip.chill,
    MoodChip.energetic,
    MoodChip.focus,
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.s4),
        itemCount: visualOrder.length,
        separatorBuilder: (_, _) => SizedBox(width: tokens.s2),
        itemBuilder: (context, i) {
          final chip = visualOrder[i];
          final isSelected =
              controller.isMulti && controller.selected.contains(chip);
          final body = FilterChip(
            selected: isSelected,
            label: Text(_label(chip)),
            avatar: Icon(_iconFor(chip), size: 18),
            onSelected: (_) => _onTap(context, chip),
          );
          return Opacity(opacity: dim ? 0.5 : 1.0, child: body);
        },
      ),
    );
  }

  void _onTap(BuildContext context, MoodChip chip) {
    if (!controller.isMulti) {
      Navigator.of(context).push(MoodResultsScreen.route(chip));
      return;
    }
    final next = Set<MoodChip>.from(controller.selected);
    if (next.contains(chip)) {
      next.remove(chip);
    } else {
      next.add(chip);
    }
    controller.onChanged?.call(next);
  }

  static String _label(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return 'Happy';
      case MoodChip.sad:
        return 'Sad';
      case MoodChip.chill:
        return 'Chill';
      case MoodChip.energetic:
        return 'Energetic';
      case MoodChip.focus:
        return 'Focus';
    }
  }

  static IconData _iconFor(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return Icons.sentiment_very_satisfied_outlined;
      case MoodChip.sad:
        return Icons.sentiment_dissatisfied_outlined;
      case MoodChip.chill:
        return Icons.spa_outlined;
      case MoodChip.energetic:
        return Icons.flash_on_outlined;
      case MoodChip.focus:
        return Icons.center_focus_strong_outlined;
    }
  }
}
```

`HomeScreen` already calls `const MoodChipRow()` with no controller argument; the new default-single constructor preserves identical behaviour. No edit needed in `home_screen.dart`.

- [ ] **Step 4: Run all mood_chip_row tests + every other test that touches MoodChipRow**

Run:
```
cd apps/mobile && flutter test test/mood_chip_row_test.dart
cd apps/mobile && flutter test test/widget_test.dart
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/widgets/mood_chip_row.dart apps/mobile/test/mood_chip_row_test.dart
git commit -m "mobile: add MoodChipController for single + multi-select modes

Slice-4 single-mode behaviour (tap pushes MoodResultsScreen) preserved
via MoodChipController.single() default. Slice-10 multi mode
(.multi(initial:, onChanged:)) introduced for the Songs tab. Adds an
optional dim flag for the True-Shuffle ON visual state. Locked visual
order and FilterChip count unchanged — slice-4 widget tests still
pass."
```

---

### Task 6: `_normalizeArtist` + two-pass `indexAlbums`

Implements the album-grouping bug fix from spec §2.4. Pass 1 walks the merged track list and computes a canonical `albumArtist` per album-title group (most-frequent non-null wins; ties broken by first-seen order). Pass 2 groups by `(canonical-album-artist OR _normalizeArtist(track.artist)) ∷ album`. Track tag values stay verbatim; only the grouping/projection sees the normalised artist.

**Files:**
- Modify: `apps/mobile/lib/browse/album_view.dart`
- Test: `apps/mobile/test/album_grouping_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/album_grouping_test.dart`:

```dart
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
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/album_grouping_test.dart`
Expected: FAIL — current single-pass `indexAlbums` does not normalise feat./ft. so the "X feat. Y" tracks land in their own group.

- [ ] **Step 3: Implement `_normalizeArtist` + two-pass refactor**

Replace the `_idFor`, `_albumArtist`, and `indexAlbums` functions in `apps/mobile/lib/browse/album_view.dart` with:

```dart
/// Pure derivation: groups [tracks] using a two-pass canonical-album-
/// artist resolution that fixes the slice-10 §2.4 grouping bug.
///
/// Pass 1 — walk every track. For each `(album-title-lower, trimmed)`
/// key, collect the multiset of distinct non-null `albumArtist` values.
/// The canonical artist for that title is the most-frequent non-null
/// entry (ties broken by first-seen order to keep grouping deterministic
/// across rebuilds).
///
/// Pass 2 — group every track. The id is
/// `<canonicalAlbumArtist OR _normalizeArtist(track.artist)> ∷ <album>`.
/// `Track.albumArtist` is never mutated; the original tag flows
/// untouched into the queue / palette / radio paths.
List<AlbumView> indexAlbums(
  List<Track> tracks,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  // Pass 1 — collect canonical album-artist hints per album title.
  final seenOrder = <String, List<String>>{};
  final counts = <String, Map<String, int>>{};
  for (final t in tracks) {
    final albumKey = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim().toLowerCase()
        : 'unknown album';
    final aa = t.albumArtist?.trim();
    if (aa == null || aa.isEmpty) continue;
    final list = seenOrder.putIfAbsent(albumKey, () => <String>[]);
    if (!list.contains(aa)) list.add(aa);
    final m = counts.putIfAbsent(albumKey, () => <String, int>{});
    m.update(aa, (c) => c + 1, ifAbsent: () => 1);
  }
  final canonicalByAlbum = <String, String>{};
  counts.forEach((albumKey, m) {
    String? bestKey;
    var bestCount = -1;
    for (final entry in seenOrder[albumKey]!) {
      final c = m[entry] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        bestKey = entry;
      }
    }
    if (bestKey != null) canonicalByAlbum[albumKey] = bestKey;
  });

  // Pass 2 — group each track using the canonical hint or the
  // normalised artist fallback.
  final groups = <String, List<Track>>{};
  final groupArtistDisplay = <String, String>{};
  for (final t in tracks) {
    final albumKey = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim().toLowerCase()
        : 'unknown album';
    final canonical = canonicalByAlbum[albumKey];
    final groupArtist = canonical ?? _normalizeArtist(t.artist ?? '');
    final albumDisplay = (t.album?.trim().isNotEmpty ?? false)
        ? t.album!.trim()
        : 'Unknown Album';
    final id = '$groupArtist∷$albumDisplay';
    groups.putIfAbsent(id, () => <Track>[]).add(t);
    groupArtistDisplay.putIfAbsent(id, () {
      if (groupArtist.isNotEmpty) return groupArtist;
      return 'Unknown Artist';
    });
  }
  final views = groups.entries
      .map((e) => _buildAlbumView(
            e.key,
            e.value,
            groupArtistDisplay[e.key] ?? 'Unknown Artist',
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
  String id,
  List<Track> ts,
  String artistDisplay,
  Map<String, String?> releaseMbidByPath,
  Map<String, String?> coverByReleaseMbid,
) {
  String? releaseMbid;
  String? coverUrl;
  for (final t in ts) {
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
  return AlbumView(
    id: id,
    title: _albumTitle(ts.first),
    artist: artistDisplay,
    year: _firstYear(ts),
    coverUrl: coverUrl,
    releaseMbid: releaseMbid,
    tracks: List.unmodifiable(ts),
  );
}

String _albumTitle(Track t) {
  final al = t.album?.trim();
  if (al == null || al.isEmpty) return 'Unknown Album';
  return al;
}

int? _firstYear(List<Track> ts) {
  for (final t in ts) {
    if (t.year != null) return t.year;
  }
  return null;
}

/// Strips collaborator suffixes from an artist string. Case-insensitive
/// match against `feat.`, `ft.`, `featuring`, `(feat. …)`, `(with …)`.
/// `&` and `,` separators do not strip — they imply genuine multi-artist
/// credits the user usually wants kept distinct.
///
/// Single-pass regex match — strips from the first marker onward, so
/// `X feat. Y feat. Z` becomes `X`. Keeps trim semantics consistent
/// with the rest of the album indexer.
String _normalizeArtist(String input) {
  if (input.trim().isEmpty) return '';
  // The regex matches `(feat. anything-to-end)`, `(with anything)`,
  // `(ft. anything)`, `feat. ...`, `ft. ...`, `featuring ...`,
  // case-insensitively. The `\s+` before the marker prevents matching
  // inside artist names that happen to contain "ft" as a substring.
  final stripped = input.replaceFirst(
    RegExp(
      r'\s*(?:[(\[]\s*)?'
      r'(?:feat\.?|ft\.?|featuring|with)\s'
      r'.*$',
      caseSensitive: false,
    ),
    '',
  );
  return stripped.trim();
}
```

- [ ] **Step 4: Run the new tests + every existing test that calls `indexAlbums`**

Run:
```
cd apps/mobile && flutter test test/album_grouping_test.dart
cd apps/mobile && flutter test test/browse_providers_test.dart
```

Expected: both pass. If `browse_providers_test.dart` asserted any specific grouping behaviour that the bug fix changes (it shouldn't — slice-2 fixtures use clean tags), surface that as a real failure and update fixture data, not the algorithm.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/browse/album_view.dart apps/mobile/test/album_grouping_test.dart
git commit -m "mobile: two-pass album grouping with feat./ALBUMARTIST resolution

Pass 1 tallies non-null albumArtist values per album title; the
most-frequent (with first-seen tiebreaker) becomes the canonical
album-artist. Pass 2 groups each track by either the canonical artist
or _normalizeArtist(track.artist) when no albumArtist exists for the
title. _normalizeArtist strips feat./ft./featuring/(with) suffixes
case-insensitively; & and , separators are preserved.

Track.albumArtist is never mutated (Slice-10 §2.4 non-destructive
guarantee). The album-grouping_v2 hero-id mitigation lands with the
gating flag in Task 17."
```

---

## Phase C — Songs surface + Discover Home

### Task 7: `SongsShuffleTab` (Songs body becomes the iPod-shuffle surface)

The new Songs tab body — Shuffle CTA, multi-select MoodChipRow, tempo dropdown, True-Shuffle / Infinite toggles, deck list. Consumes `MoodChipController.multi` (Task 5), `VibeShuffleQuery` (Task 4), and the `TempoBand` enum from `vibe_query.dart`. The Infinite toggle's lookahead trigger lands in Task 12 — for this task the toggle is rendered but does not yet wire into the radio session.

**Files:**
- Create: `apps/mobile/lib/screens/songs_shuffle_tab.dart`
- Create: `apps/mobile/lib/providers/songs_shuffle_providers.dart` (state + query providers)
- Modify: `apps/mobile/lib/screens/library_screen.dart` (replace `_SongsTab` body with `SongsShuffleTab`)
- Test: `apps/mobile/test/songs_shuffle_tab_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/songs_shuffle_tab_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/songs_shuffle_providers.dart';
import 'package:mobile/screens/songs_shuffle_tab.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders shuffle CTA + chip row + tempo dropdown',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async => const <ShuffleTrack>[
                ShuffleTrack(
                  trackId: 1,
                  path: '/a.flac',
                  title: 'A',
                  artist: 'X',
                  album: 'Y',
                  score: 0.9,
                  bpm: 100,
                ),
              ]),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Shuffle play'), findsOneWidget);
    expect(find.text('True Shuffle'), findsOneWidget);
    expect(find.text('Steer by vibe'), findsOneWidget);
  });

  testWidgets('toggling a chip refreshes the deck via shuffleDeckProvider',
      (tester) async {
    var lastChipsSeen = <MoodChip>{};
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async {
            final state = ref.watch(songsShuffleStateProvider);
            lastChipsSeen = state.chips;
            return const <ShuffleTrack>[];
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap the Chill chip; deck refresh sees {chill}.
    await tester.tap(find.text('Chill'));
    await tester.pumpAndSettle();
    expect(lastChipsSeen, equals(<MoodChip>{MoodChip.chill}));

    // Tap Focus → {chill, focus}.
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(lastChipsSeen, equals(<MoodChip>{MoodChip.chill, MoodChip.focus}));
  });

  testWidgets('True Shuffle toggle dims chips and bypasses chip mode',
      (tester) async {
    var lastTrueShuffle = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async {
            final state = ref.watch(songsShuffleStateProvider);
            lastTrueShuffle = state.trueShuffle;
            return const <ShuffleTrack>[];
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('songs.trueShuffleToggle')));
    await tester.pumpAndSettle();
    expect(lastTrueShuffle, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/songs_shuffle_tab_test.dart`
Expected: FAIL — `SongsShuffleTab`, `shuffleDeckProvider`, `songsShuffleStateProvider` undefined.

- [ ] **Step 3: Create the state + query providers**

Create `apps/mobile/lib/providers/songs_shuffle_providers.dart`:

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Aggregate state for the Songs-tab shuffle UI. Held in a Notifier so
/// chip + tempo toggles publish a single new value to the deck query.
class SongsShuffleState {
  /// Currently-selected mood chips (multi-select). Empty by default.
  final Set<MoodChip> chips;

  /// Tempo band (or null = "Any tempo").
  final TempoBand? band;

  /// True-Shuffle override. When true, the deck ignores chip selections
  /// and returns a uniformly-random ready set; the chips render dimmed
  /// per spec §2.2.
  final bool trueShuffle;

  /// Infinite radio toggle. Wired to the lookahead trigger in Task 12.
  /// State stored here so the toggle's UI position survives chip changes.
  final bool infinite;

  const SongsShuffleState({
    this.chips = const <MoodChip>{},
    this.band,
    this.trueShuffle = false,
    this.infinite = false,
  });

  SongsShuffleState copyWith({
    Set<MoodChip>? chips,
    Object? band = _sentinel,
    bool? trueShuffle,
    bool? infinite,
  }) {
    return SongsShuffleState(
      chips: chips ?? this.chips,
      band: band == _sentinel ? this.band : band as TempoBand?,
      trueShuffle: trueShuffle ?? this.trueShuffle,
      infinite: infinite ?? this.infinite,
    );
  }
}

const _sentinel = Object();

class SongsShuffleStateNotifier extends Notifier<SongsShuffleState> {
  @override
  SongsShuffleState build() => const SongsShuffleState();

  void setChips(Set<MoodChip> chips) {
    state = state.copyWith(chips: chips);
  }

  void setBand(TempoBand? band) {
    state = state.copyWith(band: band);
  }

  void setTrueShuffle(bool value) {
    state = state.copyWith(trueShuffle: value);
  }

  void setInfinite(bool value) {
    state = state.copyWith(infinite: value);
  }
}

final songsShuffleStateProvider =
    NotifierProvider<SongsShuffleStateNotifier, SongsShuffleState>(
  SongsShuffleStateNotifier.new,
);

/// The visible deck. Re-runs `VibeShuffleQuery` on every state change.
/// Debounced 250 ms (slice 10 §7 risk 3) so rapid chip toggles don't
/// thrash the SQL.
final shuffleDeckProvider =
    FutureProvider.autoDispose<List<ShuffleTrack>>((ref) async {
  final state = ref.watch(songsShuffleStateProvider);
  // Debounce: wait 250 ms; if the state changes during the wait the
  // FutureProvider re-runs and the in-flight call is auto-disposed.
  final completer = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 250), completer.complete);
  ref.onDispose(timer.cancel);
  await completer.future;
  final db = await ref.watch(cacheDbProvider.future);
  return db.vibeShuffle.run(
    chips: state.chips,
    band: state.band,
    trueShuffle: state.trueShuffle,
  );
});
```

- [ ] **Step 4: Implement `SongsShuffleTab`**

Create `apps/mobile/lib/screens/songs_shuffle_tab.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/cache_db_providers.dart';
import '../providers/playback_providers.dart';
import '../providers/songs_shuffle_providers.dart';
import '../widgets/mood_chip_row.dart';

/// Slice 10 §2.2 — Library → Songs is now the iPod-shuffle surface.
/// Top: big Shuffle Play CTA + True Shuffle + Infinite toggles.
/// Middle: multi-select mood chip row + tempo dropdown.
/// Bottom: live deck list. Tap a row to play from there; the rest of
/// the visible deck loads as the queue tail.
class SongsShuffleTab extends ConsumerWidget {
  const SongsShuffleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final state = ref.watch(songsShuffleStateProvider);
    final deckAsync = ref.watch(shuffleDeckProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Shuffle CTA + toggles row.
        Padding(
          padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s4, tokens.s2),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _shufflePlay(ref, deckAsync.asData?.value ?? const []),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle play'),
                ),
              ),
              SizedBox(width: tokens.s3),
              FilterChip(
                key: const Key('songs.trueShuffleToggle'),
                label: const Text('True Shuffle'),
                selected: state.trueShuffle,
                onSelected: (v) => ref
                    .read(songsShuffleStateProvider.notifier)
                    .setTrueShuffle(v),
              ),
              SizedBox(width: tokens.s2),
              FilterChip(
                key: const Key('songs.infiniteToggle'),
                label: const Text('Infinite'),
                avatar: const Icon(Icons.all_inclusive, size: 18),
                selected: state.infinite,
                onSelected: (v) => ref
                    .read(songsShuffleStateProvider.notifier)
                    .setInfinite(v),
              ),
            ],
          ),
        ),
        // "Steer by vibe" header + multi-select chip row.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1),
          child: Text('Steer by vibe',
              style: scale.caption13.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ),
        MoodChipRow(
          dim: state.trueShuffle,
          controller: MoodChipController.multi(
            initial: state.chips,
            onChanged: (next) => ref
                .read(songsShuffleStateProvider.notifier)
                .setChips(next),
          ),
        ),
        // Tempo dropdown row.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _TempoDropdown(
              value: state.band,
              onChanged: (b) => ref
                  .read(songsShuffleStateProvider.notifier)
                  .setBand(b),
            ),
          ),
        ),
        const Divider(height: 1),
        // Deck count + list.
        deckAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: EdgeInsets.all(tokens.s4),
            child: Text('Shuffle query failed: $e',
                style: TextStyle(color: theme.colorScheme.error)),
          ),
          data: (deck) {
            if (deck.isEmpty) {
              return Padding(
                padding: EdgeInsets.all(tokens.s6),
                child: Center(
                  child: Text(
                    'No tracks match — pick fewer chips or try True Shuffle.',
                    style: scale.body16,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s4, tokens.s1),
              child: Text(
                'Showing ${deck.length} tracks',
                style: scale.caption13.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          },
        ),
        Expanded(
          child: deckAsync.maybeWhen(
            orElse: () => const SizedBox.shrink(),
            data: (deck) => ListView.builder(
              itemCount: deck.length,
              itemBuilder: (context, i) {
                final t = deck[i];
                return ListTile(
                  title: Text(
                    t.title ?? _basename(t.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [t.artist, t.album]
                        .whereType<String>()
                        .where((s) => s.isNotEmpty)
                        .join(' — '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: t.bpm != null
                      ? Text('${t.bpm!.toStringAsFixed(0)} bpm')
                      : null,
                  onTap: () => _playFromIndex(ref, deck, i),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _shufflePlay(WidgetRef ref, List<ShuffleTrack> deck) {
    if (deck.isEmpty) return;
    // Convert ShuffleTrack to Track via the deck's tag fields. Each
    // ShuffleTrack carries the path verbatim, which is the queue
    // service's identity key.
    final tracks = [
      for (final t in deck)
        Track(
          path: t.path,
          mtimeMs: 0,
          title: t.title,
          artist: t.artist,
          album: t.album,
        ),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: 0);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  void _playFromIndex(WidgetRef ref, List<ShuffleTrack> deck, int i) {
    if (deck.isEmpty) return;
    final tracks = [
      for (final t in deck)
        Track(
          path: t.path,
          mtimeMs: 0,
          title: t.title,
          artist: t.artist,
          album: t.album,
        ),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: i);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    final base = i < 0 ? path : path.substring(i + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

class _TempoDropdown extends StatelessWidget {
  const _TempoDropdown({required this.value, required this.onChanged});
  final TempoBand? value;
  final ValueChanged<TempoBand?> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<TempoBand?>(
      tooltip: 'Tempo',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => const [
        PopupMenuItem<TempoBand?>(value: null, child: Text('Any tempo')),
        PopupMenuItem<TempoBand?>(value: TempoBand.calm, child: Text('Calm (<90)')),
        PopupMenuItem<TempoBand?>(value: TempoBand.mid, child: Text('Mid (90–120)')),
        PopupMenuItem<TempoBand?>(value: TempoBand.hot, child: Text('Hot (>120)')),
      ],
      child: Chip(
        avatar: const Icon(Icons.speed_outlined, size: 18),
        label: Text(_label(value)),
      ),
    );
  }

  static String _label(TempoBand? band) {
    switch (band) {
      case null:
        return 'Any tempo';
      case TempoBand.calm:
        return 'Calm';
      case TempoBand.mid:
        return 'Mid';
      case TempoBand.hot:
        return 'Hot';
    }
  }
}
```

- [ ] **Step 5: Wire `SongsShuffleTab` into `_SongsTab` in `library_screen.dart`**

Edit `apps/mobile/lib/screens/library_screen.dart`. Replace the existing `_SongsTab` class body (lines ~232–245):

```dart
class _SongsTab extends StatelessWidget {
  const _SongsTab();
  @override
  Widget build(BuildContext context) => const SongsShuffleTab();
}
```

Add the import at the top of `library_screen.dart`:

```dart
import 'songs_shuffle_tab.dart';
```

Remove the now-unused `_SongsList` class and its private helpers (`_displayTitle`, `_subtitleOf`, `_formatDuration`) — they were the slice-1 flat-list body that the new tab replaces. Also remove the `import 'package:prism_core/core.dart';` if nothing else in the file references `Track` directly (a quick visual scan confirms whether the symbol is still used; if not, drop the import).

- [ ] **Step 6: Run the new test plus every existing flutter test**

Run:
```
cd apps/mobile && flutter test test/songs_shuffle_tab_test.dart
cd apps/mobile && flutter test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/providers/songs_shuffle_providers.dart apps/mobile/lib/screens/songs_shuffle_tab.dart apps/mobile/lib/screens/library_screen.dart apps/mobile/test/songs_shuffle_tab_test.dart
git commit -m "mobile: SongsShuffleTab replaces slice-1 _SongsList body

Library → Songs is now the iPod-shuffle surface. Multi-select
MoodChipRow + tempo dropdown drive VibeShuffleQuery; True-Shuffle and
Infinite toggles render alongside the Shuffle CTA. Deck list updates
on chip toggles via shuffleDeckProvider (debounced 250 ms). Tap-to-
play loads the visible deck into the queue from the tapped row.

Infinite-toggle lookahead trigger lands in a later commit (Task 12)."
```

---

### Task 8: `DiscoverGrids` on Home (retire `RandomTab`)

Lifts the `_AlbumsSection` + `_ArtistsSection` from `random_tab.dart` into private `DiscoverAlbumsGrid` + `DiscoverArtistsGrid` widgets in `apps/mobile/lib/widgets/discover_grids.dart`. Inserts both into HomeScreen between the Featured row and the Artists row. Independent seeds — refresh button per grid — preserved per slice-2 invariant. `random_tab.dart` and the `RadioHomeCard` import in HomeScreen are dropped.

**Files:**
- Create: `apps/mobile/lib/widgets/discover_grids.dart`
- Create: `apps/mobile/test/discover_grids_test.dart` (migrated from `random_tab_test.dart`)
- Modify: `apps/mobile/lib/screens/home_screen.dart` (insert the two grids)
- Delete: `apps/mobile/lib/screens/random_tab.dart`
- Delete: `apps/mobile/test/random_tab_test.dart`

(`RadioHomeCard` is not currently rendered in `HomeScreen` — its source files are deleted in Task 19, separately, since the slice-5 retirement work also touches `queue_screen.dart`.)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/discover_grids_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/browse/artist_view.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/discover_grids.dart';

void main() {
  testWidgets('DiscoverAlbumsGrid renders 6 album tiles', (tester) async {
    final albums = _fixtureAlbums(20);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider.overrideWith((ref) => AsyncValue.data(albums)),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: DiscoverAlbumsGrid()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Album '), findsNWidgets(6));
  });

  testWidgets('DiscoverArtistsGrid renders 6 artist tiles', (tester) async {
    final artists = _fixtureArtists(20);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          artistsProvider.overrideWith((ref) => AsyncValue.data(artists)),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: DiscoverArtistsGrid()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Artist '), findsNWidgets(6));
  });

  testWidgets('per-grid refresh changes only that grid', (tester) async {
    final albums = _fixtureAlbums(20);
    final artists = _fixtureArtists(20);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider.overrideWith((ref) => AsyncValue.data(albums)),
          artistsProvider.overrideWith((ref) => AsyncValue.data(artists)),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: Scaffold(
            body: ListView(
              children: const [
                DiscoverAlbumsGrid(),
                DiscoverArtistsGrid(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final initialAlbums = _visibleTitlesContaining(tester, 'Album ');
    final initialArtists = _visibleTitlesContaining(tester, 'Artist ');
    final refreshes = find.byTooltip('Refresh');
    expect(refreshes, findsNWidgets(2),
        reason: 'one refresh per grid');

    await tester.tap(refreshes.first);
    await tester.pumpAndSettle();
    final afterAlbums = _visibleTitlesContaining(tester, 'Album ');
    final unchangedArtists = _visibleTitlesContaining(tester, 'Artist ');

    expect(unchangedArtists, equals(initialArtists),
        reason: 'artist seed must not change when album refresh fires');
    expect(afterAlbums, isNot(equals(initialAlbums)),
        reason: 'album seed should reseed to a new ordering');
  });
}

List<String> _visibleTitlesContaining(WidgetTester tester, String prefix) {
  return find
      .byWidgetPredicate(
        (w) => w is Text && (w.data?.contains(prefix) ?? false),
      )
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
}

List<AlbumView> _fixtureAlbums(int n) => List.generate(
      n,
      (i) => AlbumView(
        id: 'id-$i',
        title: 'Album $i',
        artist: 'Filler',
        tracks: const [],
      ),
    );

List<ArtistView> _fixtureArtists(int n) => List.generate(
      n,
      (i) => ArtistView(
        id: 'art-$i',
        name: 'Artist $i',
        albumCount: 1,
        trackCount: 1,
        albums: const [],
        topTracks: const [],
      ),
    );
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/discover_grids_test.dart`
Expected: FAIL — `discover_grids.dart` does not exist.

- [ ] **Step 3: Implement `discover_grids.dart`**

Create `apps/mobile/lib/widgets/discover_grids.dart`:

```dart
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../providers/metadata_providers.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';
import 'album_tile.dart';
import 'artist_tile.dart';
import 'refresh_icon_button.dart';

/// Slice 10 §2.1 — Discover albums grid lifted from the retired
/// `RandomTab`. 2x3 grid, independent reseed via the grid's own
/// refresh button. Mounted on Home between the Featured row and the
/// Artists row.
class DiscoverAlbumsGrid extends ConsumerStatefulWidget {
  const DiscoverAlbumsGrid({super.key});

  @override
  ConsumerState<DiscoverAlbumsGrid> createState() =>
      _DiscoverAlbumsGridState();
}

class _DiscoverAlbumsGridState extends ConsumerState<DiscoverAlbumsGrid> {
  int _seed = DateTime.now().microsecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final albumsAsync = ref.watch(albumsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Discover albums',
          onRefresh: () => setState(() {
            _seed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: albumsAsync.when(
            loading: () => const _Loading(),
            error: (e, _) => const _Error('Library unavailable'),
            data: (all) => all.isEmpty
                ? const _Empty('No albums yet.')
                : _AlbumTiles(albums: _pick(all)),
          ),
        ),
      ],
    );
  }

  List<AlbumView> _pick(List<AlbumView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_seed))).take(6).toList();
  }
}

/// Slice 10 §2.1 — Discover artists grid. Independent seed (mixed-in
/// hex constant so the two seeds aren't trivially correlated when the
/// clock has low entropy on emulators — same trick the retired
/// RandomTab used).
class DiscoverArtistsGrid extends ConsumerStatefulWidget {
  const DiscoverArtistsGrid({super.key});

  @override
  ConsumerState<DiscoverArtistsGrid> createState() =>
      _DiscoverArtistsGridState();
}

class _DiscoverArtistsGridState extends ConsumerState<DiscoverArtistsGrid> {
  int _seed = DateTime.now().microsecondsSinceEpoch ^ 0x9E3779B1;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final artistsAsync = ref.watch(artistsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Discover artists',
          onRefresh: () => setState(() {
            _seed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: artistsAsync.when(
            loading: () => const _Loading(),
            error: (e, _) => const _Error('Library unavailable'),
            data: (all) => all.isEmpty
                ? const _Empty('No artists yet.')
                : _ArtistTiles(artists: _pick(all)),
          ),
        ),
      ],
    );
  }

  List<ArtistView> _pick(List<ArtistView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_seed))).take(6).toList();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onRefresh});
  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s2, tokens.s2),
      child: Row(
        children: [
          Text(title, style: scale.display20),
          const Spacer(),
          RefreshIconButton(onPressed: onRefresh),
        ],
      ),
    );
  }
}

class _AlbumTiles extends StatelessWidget {
  const _AlbumTiles({required this.albums});
  final List<AlbumView> albums;
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: tokens.s3,
      crossAxisSpacing: tokens.s3,
      childAspectRatio: 0.75,
      children: [
        for (final a in albums)
          AlbumTile(
            album: a,
            onTap: () => Navigator.of(context).push(
              AlbumDetailScreen.route(a.id),
            ),
          ),
      ],
    );
  }
}

class _ArtistTiles extends StatelessWidget {
  const _ArtistTiles({required this.artists});
  final List<ArtistView> artists;
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: tokens.s3,
      crossAxisSpacing: tokens.s3,
      childAspectRatio: 0.78,
      children: [
        for (final a in artists)
          ArtistTile(
            artist: a,
            onTap: () => Navigator.of(context).push(
              ArtistDetailScreen.route(a.id),
            ),
          ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
}

class _Error extends StatelessWidget {
  const _Error(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(message,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Center(child: Text(message)));
}
```

- [ ] **Step 4: Insert the grids into HomeScreen**

Edit `apps/mobile/lib/screens/home_screen.dart`. Add an import at the top:

```dart
import '../widgets/discover_grids.dart';
```

In the body's children list inside `HomeScreen.build`, after the `_FeaturedRow()` entry and before `_ArtistsRow()`, insert:

```dart
            SizedBox(height: tokens.s4),
            const DiscoverAlbumsGrid(),
            SizedBox(height: tokens.s4),
            const DiscoverArtistsGrid(),
```

The resulting children sequence should be:

```
_GreetingBlock → _ComposeCard → Mood section → _FeaturedRow →
DiscoverAlbumsGrid → DiscoverArtistsGrid → _ArtistsRow → _RecentlyPlayedGrid
```

- [ ] **Step 5: Delete `random_tab.dart` and `random_tab_test.dart`**

```bash
git rm apps/mobile/lib/screens/random_tab.dart apps/mobile/test/random_tab_test.dart
```

- [ ] **Step 6: Run the full mobile test suite**

Run: `cd apps/mobile && flutter test`
Expected: all tests pass — including the new `discover_grids_test.dart`.

Run: `flutter analyze`
Expected: no issues. (If unused-import warnings surface in `library_screen.dart` from Task 7, fix them inline.)

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/widgets/discover_grids.dart apps/mobile/lib/screens/home_screen.dart apps/mobile/test/discover_grids_test.dart
git rm --cached apps/mobile/lib/screens/random_tab.dart apps/mobile/test/random_tab_test.dart 2>/dev/null || true
git commit -m "mobile: lift RandomTab into DiscoverAlbumsGrid + DiscoverArtistsGrid

Slice 10 §2.1 — Random tab retired; its two sections move into Home as
2x3 discover grids with independent seeds (slice-2 invariant: refreshing
one grid does not reseed the other). Mounted between the Featured row
and the Artists row.

random_tab.dart + random_tab_test.dart deleted; per-grid behaviour
covered by discover_grids_test.dart."
```

---

## Phase D — Radio integrations

### Task 9: Glass-pill restyle + parent-layout guard for `RadioBadge` / `SteerChipBar`

`RadioBadge` and `SteerChipBar` already short-circuit on null session — but `NowPlayingScreen._PlayerView` wraps them in an `Align` + `SizedBox(height: tokens.s2)` (badge) and renders the SteerChipBar inline above the scrubber. When no session is active, those wrappers still consume layout. This task wraps both in a `_RadioRegion` that returns `SizedBox.shrink()` at the parent level, then restyles the active-state pills with `Glass(intensity: light, tint: palette.dominant)`.

**Files:**
- Modify: `apps/mobile/lib/widgets/radio_badge.dart`
- Modify: `apps/mobile/lib/widgets/steer_chip_bar.dart`
- Modify: `apps/mobile/lib/screens/now_playing_screen.dart`
- Test: `apps/mobile/test/now_playing_radio_visibility_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/now_playing_radio_visibility_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/playback_providers.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/screens/now_playing_screen.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/radio_badge.dart';
import 'package:mobile/widgets/steer_chip_bar.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

void main() {
  testWidgets('no radio session: neither RadioBadge nor SteerChipBar render',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _baseOverrides,
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const NowPlayingScreen(),
        ),
      ),
    );
    await tester.pump();

    // Both widgets should be absent from the tree (not just shrunk).
    expect(find.byType(RadioBadge), findsNothing);
    expect(find.byType(SteerChipBar), findsNothing);
  });

  testWidgets('active session: both render and SteerChipBar accepts taps',
      (tester) async {
    final fakeSession = RadioSession(
      seed: const TrackSeed(trackId: 1, title: 'Seed'),
      seedEmbedding: Float32List(1280)..[0] = 1.0,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._baseOverrides,
          radioSessionProvider.overrideWith(
            () => _StubRadioNotifier(fakeSession),
          ),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const NowPlayingScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RadioBadge), findsOneWidget);
    expect(find.text('RADIO'), findsOneWidget);
    expect(find.byType(SteerChipBar), findsOneWidget);
  });
}

final _baseOverrides = <Override>[
  // The cast / playback providers reach for path_provider / channel
  // mocks otherwise; we override the bare minimum so NowPlayingScreen
  // can build without a real audio handler.
  nowPlayingProvider.overrideWith(
    (ref) => Stream.value(
      const Track(path: '/x.flac', mtimeMs: 0, title: 'Title'),
    ),
  ),
  positionProvider.overrideWith((ref) => Stream.value(Duration.zero)),
  durationProvider.overrideWith((ref) => Stream.value(Duration.zero)),
  playerStateProvider.overrideWith(
    (ref) => const Stream<PlayerState>.empty(),
  ),
  transportProvider.overrideWith(
    () => _StubTransport(),
  ),
];

class _StubRadioNotifier extends RadioSessionNotifier {
  _StubRadioNotifier(this._initial);
  final RadioSession _initial;
  @override
  RadioSession? build() => _initial;
}

class _StubTransport extends Notifier<CastTransport> {
  @override
  CastTransport build() => throw UnimplementedError();
}
```

> **Note:** the imports / override list above will need a one-pass adjust for whatever the actual `transportProvider` / `playerStateProvider` types resolve to in the workspace. If `playerStateProvider` is a `StreamProvider` the override is `(ref) => Stream<PlayerState>.empty()`. The test author may need to adapt to the package API rather than match the import names verbatim.

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/now_playing_radio_visibility_test.dart`
Expected: FAIL — the parent layout still wraps the widgets, so `find.byType(RadioBadge)` succeeds even when null session — current behaviour returns SizedBox.shrink() but the widget itself is still in the tree.

(If the test passes already because RadioBadge / SteerChipBar are mounted but invisible, the test's `findsNothing` assertion captures the spec's "should not appear in the tree" requirement and the parent guard refactor below makes it pass for real.)

- [ ] **Step 3: Add a parent-layout guard in NowPlayingScreen**

Edit `apps/mobile/lib/screens/now_playing_screen.dart`. Add this private widget near the bottom of the file (after the existing private widgets):

```dart
/// Slice 10 §2.3 — wraps RadioBadge / SteerChipBar so the *parent* layout
/// short-circuits on no-session. Avoids the `SizedBox.shrink` zero-height
/// stub that still consumed Align / spacing rows.
class _RadioRegion extends ConsumerWidget {
  const _RadioRegion({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOn = ref.watch(radioModeProvider);
    if (!isOn) return const SizedBox.shrink();
    return child;
  }
}
```

Add the import at the top:

```dart
import '../providers/radio_providers.dart';
```

In `_PlayerView.build`, replace the existing `Align(... RadioBadge())` block (around lines 322–328) with:

```dart
          const _RadioRegion(child: RadioBadge()),
```

…and replace the existing `const SteerChipBar()` line (around line 388) with:

```dart
          const _RadioRegion(child: SteerChipBar()),
```

Drop the `SizedBox(height: tokens.s2)` that previously sat between the badge and the album art, since the region collapses to zero height when no session is active. Keep the `tokens.s2` spacer ONLY if the active-state padding looks too tight in the manual visual check.

- [ ] **Step 4: Glass-pill restyle for `RadioBadge`**

Replace `apps/mobile/lib/widgets/radio_badge.dart`'s `build` method body. Keep the import + class signature; the inside becomes:

```dart
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOn = ref.watch(radioModeProvider);
    if (!isOn) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final palette = theme.extension<AlbumPalette>();
    final tint = palette?.isNeutral == false ? palette!.dominant : null;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.s1),
      child: Glass(
        intensity: GlassIntensity.light,
        radius: 999,
        tint: tint,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.s3,
          vertical: tokens.s1 + 2,
        ),
        child: Text(
          'RADIO',
          style: scale.caption13.copyWith(
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
```

(`Glass` already accepts `tint`; the slice-7 metadata strip uses the same call shape.)

- [ ] **Step 5: Glass-pill restyle for `SteerChipBar`**

The current SteerChipBar wraps a horizontal ListView; restyle is just to swap the parent `SizedBox(height: 48)` for a `Glass(intensity: light, radius: 24)` wrapper that sits above the scrubber. Edit `apps/mobile/lib/widgets/steer_chip_bar.dart`. Replace the `return SizedBox(height: 48, ...)` block with:

```dart
    final theme = Theme.of(context);
    final palette = theme.extension<AlbumPalette>();
    final tint = palette?.isNeutral == false ? palette!.dominant : null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.s4),
      child: Glass(
        intensity: GlassIntensity.light,
        radius: 24,
        tint: tint,
        padding: EdgeInsets.symmetric(vertical: tokens.s1),
        child: SizedBox(
          height: 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: ListView.separated(
              key: ValueKey<int>(activeKey),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: tokens.s2, vertical: tokens.s1 + 2),
              itemCount: visualOrder.length,
              separatorBuilder: (_, _) => SizedBox(width: tokens.s2),
              itemBuilder: (context, i) {
                final chip = visualOrder[i];
                final state = activeChips[chip];
                final isActive = state?.isActive ?? false;
                final weight = state?.weight ?? 0.0;
                return FilterChip(
                  selected: isActive,
                  label: Text(_label(chip)),
                  avatar: Opacity(
                    opacity: 0.4 + 0.6 * weight,
                    child: Icon(_iconFor(chip), size: 18),
                  ),
                  onSelected: (_) =>
                      // ignore: discarded_futures
                      ref.read(radioSessionProvider.notifier).toggleChip(chip),
                );
              },
            ),
          ),
        ),
      ),
    );
```

Add the import for `package:prism_ui/ui.dart` if not already present (the `Glass` symbol comes from there) — the file already imports it.

- [ ] **Step 6: Run the new test + the slice-5 SteerChipBar test (locked-vocabulary assertion)**

Run:
```
cd apps/mobile && flutter test test/now_playing_radio_visibility_test.dart
cd apps/mobile && flutter test test/steer_chip_bar_test.dart
```

Expected: both pass. The slice-5 SteerChipBar test asserts the locked 10-chip visualOrder; the restyle does not touch the chip vocabulary or order.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/widgets/radio_badge.dart apps/mobile/lib/widgets/steer_chip_bar.dart apps/mobile/lib/screens/now_playing_screen.dart apps/mobile/test/now_playing_radio_visibility_test.dart
git commit -m "mobile: glass-pill restyle + parent-layout guard for RadioBadge/SteerChipBar

Slice 10 §2.3 — both widgets keep their slice-5 short-circuit but a new
_RadioRegion wrapper short-circuits the *parent* layout so no-session
truly drops the rows from the tree (no zero-height stub). Glass(light)
pills with the album-palette tint when active. Slice-5 locked-vocabulary
visualOrder for SteerChipBar unchanged."
```

---

### Task 10: `startFromCluster` on `RadioSessionNotifier`

Adds the new entry point on the notifier. Resolves each `Track`'s `trackId` via the existing `_pathToIdProvider` map, fetches each embedding via `PlaylistRepo.embeddingOf`, averages with `RadioEngine.averageEmbeddings` (Task 2), and constructs a fresh `RadioSession` with a `ClusterSeed` (Task 2). Falls through to `_bootSession` so the lookahead manager picks up the same way it does for slice-5 paths.

**Files:**
- Modify: `apps/mobile/lib/providers/radio_providers.dart` (new method on `RadioSessionNotifier`)
- Test: `apps/mobile/test/radio_cluster_seed_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/radio_cluster_seed_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:prism_core/core.dart' hide KnnHit;
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WidgetsFlutterBinding.ensureInitialized();
  });

  test('startFromCluster builds a ClusterSeed with averaged embedding',
      () async {
    final repo = _StubRepo();
    repo.addTrackWithEmbedding(1, _embedAt(0, 1.0));
    repo.addTrackWithEmbedding(2, _embedAt(1, 1.0));

    final container = ProviderContainer(
      overrides: [
        playlistRepoProvider.overrideWith((ref) async => repo),
        // Make the path → id lookup deterministic.
        // Note: a public API for overriding the private _pathToIdProvider
        // would be cleaner; this stub achieves the same by overriding
        // the FutureProvider that backs it. Adjust according to the
        // package's actual export shape — see
        // `apps/mobile/lib/providers/radio_providers.dart` Task 10 step 3.
      ],
    );
    addTearDown(container.dispose);

    final tracks = [
      const Track(path: '/a.flac', mtimeMs: 0, title: 'A'),
      const Track(path: '/b.flac', mtimeMs: 0, title: 'B'),
    ];
    await container
        .read(radioSessionProvider.notifier)
        .startFromCluster(tracks, steeringHint: 'rainy_sunday');

    final session = container.read(radioSessionProvider);
    expect(session, isNotNull);
    final seed = session!.seed;
    expect(seed, isA<ClusterSeed>());
    final cluster = seed as ClusterSeed;
    expect(cluster.steeringHint, 'rainy_sunday');
    expect(cluster.trackIds, isNotEmpty);
  });

  test('startFromCluster with zero resolvable tracks is a no-op',
      () async {
    final repo = _StubRepo();
    final container = ProviderContainer(
      overrides: [
        playlistRepoProvider.overrideWith((ref) async => repo),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(radioSessionProvider.notifier)
        .startFromCluster(const <Track>[]);
    expect(container.read(radioSessionProvider), isNull);
  });
}

Float32List _embedAt(int dim, double value) {
  final v = Float32List(1280);
  v[dim] = value;
  return v;
}

class _StubRepo implements PlaylistRepo {
  final Map<int, Float32List> _emb = {};

  void addTrackWithEmbedding(int id, Float32List e) {
    _emb[id] = e;
  }

  @override
  Future<Float32List> embeddingOf(int trackId) async {
    final e = _emb[trackId];
    if (e == null) throw StateError('no embedding for $trackId');
    return Float32List.fromList(e);
  }

  // Other methods unused by startFromCluster's resolution path; throw if
  // accidentally called so the test fails loudly.
  @override
  Future<List<KnnHit>> knnByEmbedding(Float32List seed, {int k = 200}) async =>
      <KnnHit>[];
  @override
  Future<CandidateMeta> metaOf(int trackId) async =>
      throw UnimplementedError();
  @override
  Future<List<int>> libraryWideFallback({int limit = 100}) async => const [];
  @override
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey) async => null;
  @override
  Future<Float32List?> meanEmbeddingForArtist(String artist) async => null;
  @override
  Future<List<CandidateMeta>> metaOfMany(Iterable<int> ids) async =>
      const <CandidateMeta>[];
}
```

> **Note on the path→id stub:** the existing `_pathToIdProvider` in `radio_providers.dart` is private (`_` prefix). To make `startFromCluster` testable without rewiring private state, expose a small testing seam in `radio_providers.dart` — either promote `_pathToIdProvider` to public or add an optional `pathToIdOverride` parameter on `startFromCluster`. The implementation step below uses the public-promotion approach (less invasive than a per-call override).

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/radio_cluster_seed_test.dart`
Expected: FAIL — `RadioSessionNotifier.startFromCluster` undefined.

- [ ] **Step 3: Promote `_pathToIdProvider` and `_idToPathProvider` to public, add `startFromCluster`**

Edit `apps/mobile/lib/providers/radio_providers.dart`. Rename the two private providers (drop the leading underscore):

- `_idToPathProvider` → `idToPathProvider`
- `_pathToIdProvider` → `pathToIdProvider`

Update the local references inside the same file (`trackByIdLookupProvider` watches `_idToPathProvider` — change to `idToPathProvider`; `startFromTrack` reads `_pathToIdProvider` — change to `pathToIdProvider`).

Then add the new method to `RadioSessionNotifier`. After `startFromArtist` and before `_bootSession`:

```dart
  /// Slice 10 §2.3 — third entry point. Builds a synthetic seed by
  /// averaging the embeddings of [tracks] (those that resolve to a
  /// cache_db row) and feeds the result through the same kNN entry as
  /// the slice-5 paths.
  ///
  /// Tracks whose path doesn't resolve to a `tracks.id` are skipped.
  /// When ZERO resolve, the call short-circuits with no state change —
  /// the end-of-playlist sheet's "Can't extend this playlist yet" copy
  /// (slice 10 §7 risk 5) is the surface that explains this to the
  /// user.
  Future<void> startFromCluster(
    List<Track> tracks, {
    String? steeringHint,
  }) async {
    if (tracks.isEmpty) return;
    final repo = await ref.read(playlistRepoProvider.future);
    final pathToId = await ref.read(pathToIdProvider.future);

    final ids = <int>[];
    final vectors = <Float32List>[];
    for (final t in tracks) {
      final id = pathToId[t.path];
      if (id == null) continue;
      try {
        final v = await repo.embeddingOf(id);
        ids.add(id);
        vectors.add(v);
      } catch (_) {
        // Embedding row missing or wrong length — skip the track and
        // fall through to the next.
      }
    }

    final seedEmbedding = RadioEngine.averageEmbeddings(vectors);
    if (seedEmbedding == null) {
      // No resolvable embeddings — short-circuit. The active queue
      // (the just-finished playlist) stays put; the UI surfaces the
      // empty-cluster message.
      return;
    }

    final label = steeringHint ?? 'Cluster (${ids.length})';
    final session = RadioSession(
      seed: ClusterSeed(
        trackIds: List<int>.unmodifiable(ids),
        label: label,
        steeringHint: steeringHint,
      ),
      seedEmbedding: seedEmbedding,
    );
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'cluster',
        ref: ids.join(','),
        label: label,
        lastUsedAt: DateTime.now(),
      ),
    );
  }
```

Add the imports if not already present:

```dart
import 'dart:typed_data';
```

- [ ] **Step 4: Update the test's path→id seam to use the now-public provider**

Edit `apps/mobile/test/radio_cluster_seed_test.dart`. Replace the placeholder comment in the override list with:

```dart
        pathToIdProvider.overrideWith((ref) async => const {
              '/a.flac': 1,
              '/b.flac': 2,
            }),
        // _bootSession reaches into idToPathProvider too (via
        // trackByIdLookupProvider).
        idToPathProvider.overrideWith((ref) async => const {
              1: '/a.flac',
              2: '/b.flac',
            }),
        // queueProvider, playbackServiceProvider — _bootSession reads
        // both. Stub them with no-ops; the test only inspects the
        // session published to radioSessionProvider, not playback.
        queueProvider.overrideWith(() => _NoopQueue()),
```

Then add this stub class at the bottom of the test file:

```dart
class _NoopQueue extends Notifier<QueueSnapshot> implements QueueService {
  @override
  QueueSnapshot build() => const QueueSnapshot.empty();
  @override
  void loadContext(List<Track> tracks, {int startIndex = 0}) {}
  @override
  void appendForRadio(Track track) {}
  // ... other QueueService methods you can leave unimplemented for the
  // test; if the test exercises a method that throws, add a minimal
  // override on the spot. Most _bootSession tests only need
  // appendForRadio.
}
```

> **Note:** if `_bootSession`'s `LookaheadManager.start` requires a real `currentIndexStream`, you may need to also override `playbackServiceProvider` with a fake whose `currentIndexStream` is `Stream<int?>.empty()`. The simpler alternative — and probably the one to land here — is to factor out the seed-construction logic of `startFromCluster` into a separate testable method (e.g. `Future<RadioSession?> _buildClusterSession(...)`) and have the test exercise that directly without going through `_bootSession`.

- [ ] **Step 5: Add a pure-construction helper to make the test simpler**

If the LookaheadManager wiring proves too costly to stub, refactor `startFromCluster` like this:

```dart
  /// Public for testing — constructs the session without booting the
  /// lookahead manager.
  @visibleForTesting
  Future<RadioSession?> buildClusterSession(
    List<Track> tracks, {
    String? steeringHint,
  }) async {
    if (tracks.isEmpty) return null;
    final repo = await ref.read(playlistRepoProvider.future);
    final pathToId = await ref.read(pathToIdProvider.future);
    final ids = <int>[];
    final vectors = <Float32List>[];
    for (final t in tracks) {
      final id = pathToId[t.path];
      if (id == null) continue;
      try {
        final v = await repo.embeddingOf(id);
        ids.add(id);
        vectors.add(v);
      } catch (_) {}
    }
    final seedEmbedding = RadioEngine.averageEmbeddings(vectors);
    if (seedEmbedding == null) return null;
    final label = steeringHint ?? 'Cluster (${ids.length})';
    return RadioSession(
      seed: ClusterSeed(
        trackIds: List<int>.unmodifiable(ids),
        label: label,
        steeringHint: steeringHint,
      ),
      seedEmbedding: seedEmbedding,
    );
  }

  Future<void> startFromCluster(
    List<Track> tracks, {
    String? steeringHint,
  }) async {
    final session =
        await buildClusterSession(tracks, steeringHint: steeringHint);
    if (session == null) return;
    final ids = (session.seed as ClusterSeed).trackIds;
    final label = (session.seed as ClusterSeed).label;
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'cluster',
        ref: ids.join(','),
        label: label,
        lastUsedAt: DateTime.now(),
      ),
    );
  }
```

The test calls `buildClusterSession` directly and asserts on the returned `RadioSession`. Add `import 'package:meta/meta.dart';` if not already imported.

- [ ] **Step 6: Run the new test**

Run: `cd apps/mobile && flutter test test/radio_cluster_seed_test.dart`
Expected: PASS.

- [ ] **Step 7: Confirm slice-5 radio tests still pass**

Run:
```
cd packages/playlist_engine && dart test
cd apps/mobile && flutter test test/recent_seeds_store_test.dart
cd apps/mobile && flutter test test/steer_chip_bar_test.dart
```

Expected: all pass — slice-5 RadioSession state machine is byte-identical, only the SeedRef family was extended.

- [ ] **Step 8: Commit**

```bash
git add apps/mobile/lib/providers/radio_providers.dart apps/mobile/test/radio_cluster_seed_test.dart
git commit -m "mobile: add RadioSessionNotifier.startFromCluster

Slice 10 §2.3 — third entry point. Resolves Track paths to engine ids,
fetches each embedding, averages via RadioEngine.averageEmbeddings, and
constructs a session with the new ClusterSeed. _pathToIdProvider /
_idToPathProvider promoted to public for the testing seam. Slice-5
RadioSession state machine unchanged — start/stop/chip toggle paths are
byte-identical."
```

---

### Task 11: `EndOfPlaylistSheet` + AI-Compose end-of-queue observer

The bridge that surfaces "Keep playing?" when the AI Compose playlist drains. Adds:

1. `aiComposePlaybackProvider` — `NotifierProvider<AiComposePlaybackNotifier, AiComposePlayback?>` holding `(tracks, prompt, label)` for the most-recently-launched AI playlist. Cleared on user dismiss or session start.
2. `EndOfPlaylistSheet` — bottom-sheet widget with an optional preview row + primary "Keep playing" button calling `startFromCluster` (Task 10).
3. `endOfPlaylistObserverProvider` — `Provider<void>` that listens to `queueProvider` and `aiComposePlaybackProvider`; when the queue transitions to drained AND `aiComposePlaybackProvider` is non-null AND the last-played track was in the AI playlist, it shows the sheet via a navigator key + clears the state.

**Files:**
- Create: `apps/mobile/lib/providers/ai_compose_playback_providers.dart`
- Create: `apps/mobile/lib/widgets/end_of_playlist_sheet.dart`
- Modify: `apps/mobile/lib/widgets/playlist_result_card.dart` (set `aiComposePlaybackProvider` on Play tap)
- Modify: `apps/mobile/lib/app.dart` (mount the observer; provide a `navigatorKey`)
- Test: extend `apps/mobile/test/radio_cluster_seed_test.dart` with a sheet-trigger smoke test (the dedicated `radio_cluster_seed_test` already covers the underlying notifier; the observer wiring gets a separate widget test below)

- [ ] **Step 1: Implement `aiComposePlaybackProvider`**

Create `apps/mobile/lib/providers/ai_compose_playback_providers.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

/// Captures the most-recently-launched AI Compose playlist so the
/// end-of-queue observer can decide whether the drain event should
/// trigger the "Keep playing?" sheet.
class AiComposePlayback {
  /// Resolved tracks (mapped to live `Track` rows via slice-5's
  /// `trackByIdLookupProvider`). Used as the cluster seed when the
  /// user accepts the sheet.
  final List<Track> tracks;

  /// Original LLM prompt — surfaced to the user verbatim and used as
  /// the steering hint passed into `startFromCluster`.
  final String prompt;

  /// Display label (typically the playlist's blurb).
  final String label;

  const AiComposePlayback({
    required this.tracks,
    required this.prompt,
    required this.label,
  });
}

class AiComposePlaybackNotifier extends Notifier<AiComposePlayback?> {
  @override
  AiComposePlayback? build() => null;

  void set(AiComposePlayback playback) {
    state = playback;
  }

  void clear() {
    state = null;
  }
}

final aiComposePlaybackProvider =
    NotifierProvider<AiComposePlaybackNotifier, AiComposePlayback?>(
  AiComposePlaybackNotifier.new,
);
```

- [ ] **Step 2: Implement `EndOfPlaylistSheet`**

Create `apps/mobile/lib/widgets/end_of_playlist_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/ai_compose_playback_providers.dart';
import '../providers/radio_providers.dart';

/// Slice 10 §2.3 — end-of-playlist sheet. Shown when an AI Compose
/// playlist drains. Primary action calls `startFromCluster` with the
/// playlist's tracks + the original prompt as the steering hint.
class EndOfPlaylistSheet extends ConsumerWidget {
  const EndOfPlaylistSheet({super.key, required this.playback});

  final AiComposePlayback playback;

  static Future<void> show(BuildContext context, AiComposePlayback playback) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => EndOfPlaylistSheet(playback: playback),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(tokens.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Done with this set.', style: scale.display20),
            SizedBox(height: tokens.s2),
            Text(
              'Keep going? Prism will pick more like "${playback.prompt}".',
              style: scale.body16.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.s4),
            FilledButton.icon(
              onPressed: () async {
                await ref
                    .read(radioSessionProvider.notifier)
                    .startFromCluster(
                      playback.tracks,
                      steeringHint: playback.prompt,
                    );
                ref.read(aiComposePlaybackProvider.notifier).clear();
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Keep playing'),
            ),
            SizedBox(height: tokens.s2),
            TextButton(
              onPressed: () {
                ref.read(aiComposePlaybackProvider.notifier).clear();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Wire the playlist-result-card "Play" tap to set `aiComposePlaybackProvider`**

Edit `apps/mobile/lib/widgets/playlist_result_card.dart`. In `_playFrom` (around line 114), after the `loadContext` + `play()` calls, add:

```dart
    final livePlayed = tracks; // already mapped via trackByIdLookupProvider above
    ref.read(aiComposePlaybackProvider.notifier).set(
          AiComposePlayback(
            tracks: livePlayed,
            prompt: vibe,
            label: result.blurb,
          ),
        );
```

Add the import:

```dart
import '../providers/ai_compose_playback_providers.dart';
```

- [ ] **Step 4: Mount the end-of-queue observer in `PrismApp`**

Edit `apps/mobile/lib/app.dart`. Replace the body of `PrismApp.build` with:

```dart
class PrismApp extends ConsumerStatefulWidget {
  const PrismApp({super.key});
  @override
  ConsumerState<PrismApp> createState() => _PrismAppState();
}

class _PrismAppState extends ConsumerState<PrismApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    // End-of-queue observer: when the queue drains AND an AI Compose
    // playback is registered AND the last-known current was in that
    // playlist, surface the sheet and clear the registered state.
    ref.listen<QueueSnapshot>(queueProvider, (prev, next) {
      if (prev == null) return;
      final hadCurrent = prev.current != null;
      final drained = next.current == null &&
          next.upcoming.isEmpty &&
          next.playNext.isEmpty;
      if (!(hadCurrent && drained)) return;
      final aiPlayback = ref.read(aiComposePlaybackProvider);
      if (aiPlayback == null) return;
      final lastTrack = prev.current!;
      final partOfAiPlaylist =
          aiPlayback.tracks.any((t) => t.path == lastTrack.path);
      if (!partOfAiPlaylist) return;
      // Schedule the sheet on the next frame so we don't trigger
      // navigator changes inside a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _navKey.currentContext;
        if (ctx == null) return;
        // ignore: discarded_futures
        EndOfPlaylistSheet.show(ctx, aiPlayback);
      });
    });

    return MaterialApp(
      title: 'Prism',
      navigatorKey: _navKey,
      theme: PrismTheme.light(),
      initialRoute: AppShell.homeRoute,
      routes: {
        AppShell.homeRoute: (_) => const HomeScreen(),
        AppShell.searchRoute: (_) => const SearchScreen(),
        AppShell.libraryRoute: (_) => const LibraryScreen(),
        AppShell.aiRoute: (_) => const AiTabScreen(),
        '/now-playing': (_) => const NowPlayingScreen(),
        '/queue': (_) => const QueueScreen(),
        NewVibeSheet.routeName: (_) => const NewVibeSheet(),
      },
    );
  }
}
```

Add the imports:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_playback/playback.dart' show QueueSnapshot, queueProvider;

import 'providers/ai_compose_playback_providers.dart';
import 'widgets/end_of_playlist_sheet.dart';
```

- [ ] **Step 5: Run the slice-1 widget test (gear-icon walk) to make sure the PrismApp refactor didn't break it**

Run: `cd apps/mobile && flutter test test/widget_test.dart`
Expected: PASS — the gear-icon walk still finds Library + Settings; this test gets fully rewritten in Task 21.

- [ ] **Step 6: Run all flutter tests**

Run: `cd apps/mobile && flutter test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/providers/ai_compose_playback_providers.dart apps/mobile/lib/widgets/end_of_playlist_sheet.dart apps/mobile/lib/widgets/playlist_result_card.dart apps/mobile/lib/app.dart
git commit -m "mobile: end-of-playlist 'Keep playing' sheet for AI Compose

aiComposePlaybackProvider captures the most-recent AI Compose playlist
on Play tap; PrismApp's queueProvider listener detects drain events
and surfaces EndOfPlaylistSheet via a global navigator key. The sheet's
primary action calls startFromCluster with the original prompt as
steering hint, then clears the registered playback. Cancel keeps the
just-finished playlist as the active queue."
```

---

### Task 12: Songs-tab Infinite toggle → lookahead trigger

Wires the Infinite toggle on `SongsShuffleTab` to start a radio session when the queue depth (current + playNext + upcoming) drains to ~10 tracks. Uses the most-recently-played track as the seed (matching spec §2.3 row 2: "most recently played track in the deck"). The currently-selected MoodChipRow set is captured into the session at start time as initial steering — handled via `RadioSession.withChipToggled` calls on each selected MoodChip after the session boots.

**Files:**
- Modify: `apps/mobile/lib/screens/songs_shuffle_tab.dart` (mount a queue listener)
- Test: extend `apps/mobile/test/songs_shuffle_tab_test.dart`

- [ ] **Step 1: Add the failing test**

Append to `apps/mobile/test/songs_shuffle_tab_test.dart`:

```dart
  testWidgets('Infinite ON + queue at threshold triggers startFromTrack',
      (tester) async {
    var startedFrom = <Track>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shuffleDeckProvider.overrideWith((ref) async => const <ShuffleTrack>[]),
          radioSessionProvider.overrideWith(
            () => _CapturingNotifier((track) => startedFrom.add(track)),
          ),
          // Stub the queue so we can shrink it to threshold.
          queueProvider.overrideWith(() => _StaticQueue()),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: SongsShuffleTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Toggle Infinite on.
    await tester.tap(find.byKey(const Key('songs.infiniteToggle')));
    await tester.pumpAndSettle();

    // Drain the static queue below the threshold.
    final queue = ProviderScope.containerOf(
      tester.element(find.byType(SongsShuffleTab)),
    ).read(queueProvider.notifier) as _StaticQueue;
    queue.shrinkToOne();
    await tester.pumpAndSettle();

    expect(startedFrom, isNotEmpty);
  });

  // ...add the corresponding _CapturingNotifier and _StaticQueue stubs
  // at the bottom of main(); see Task 12 step 2 for shape.
```

> **Note:** the exact stub mechanics depend on `radioSessionProvider`'s constructor signature. The plan's intent is that *some* observable signal flows from the queue listener inside `SongsShuffleTab` into `RadioSessionNotifier.startFromTrack`. The test author may simplify by exercising the listener function directly instead of pumping a full widget tree.

- [ ] **Step 2: Run the test to verify failure**

Run: `cd apps/mobile && flutter test test/songs_shuffle_tab_test.dart`
Expected: FAIL — no listener wired yet.

- [ ] **Step 3: Add the queue listener inside `SongsShuffleTab`**

Convert `SongsShuffleTab` from `ConsumerWidget` to `ConsumerStatefulWidget` so we have an `initState` to register the listener. Edit `apps/mobile/lib/screens/songs_shuffle_tab.dart`:

```dart
class SongsShuffleTab extends ConsumerStatefulWidget {
  const SongsShuffleTab({super.key});
  @override
  ConsumerState<SongsShuffleTab> createState() => _SongsShuffleTabState();
}

class _SongsShuffleTabState extends ConsumerState<SongsShuffleTab> {
  /// Threshold below which Infinite triggers a radio start. Matches
  /// spec §2.3 ("when ~10 tracks remain").
  static const int _lookaheadThreshold = 10;

  /// Set once we've fired startFromTrack so a flapping queue depth
  /// doesn't spam the notifier.
  bool _radioRequested = false;

  @override
  void initState() {
    super.initState();
    // Defer until after the first frame so ref.listen can attach.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual<QueueSnapshot>(queueProvider, (prev, next) {
        final state = ref.read(songsShuffleStateProvider);
        if (!state.infinite) {
          _radioRequested = false; // toggle off resets the latch
          return;
        }
        final session = ref.read(radioSessionProvider);
        if (session != null) return; // already running
        final remaining = (next.current == null ? 0 : 1) +
            next.playNext.length +
            next.upcoming.length;
        if (remaining > _lookaheadThreshold) {
          _radioRequested = false;
          return;
        }
        if (_radioRequested) return;
        // Find the most-recently-played track; prefer current, else
        // the last in history.
        final seed = next.current ??
            (next.history.isEmpty ? null : next.history.last);
        if (seed == null) return;
        _radioRequested = true;
        // ignore: discarded_futures
        ref.read(radioSessionProvider.notifier).startFromTrack(seed).then((_) {
          // Pre-load the chip selection as initial steering.
          final chips = state.chips;
          for (final chip in chips) {
            final steerChip = _toSteerChip(chip);
            if (steerChip == null) continue;
            // ignore: discarded_futures
            ref
                .read(radioSessionProvider.notifier)
                .toggleChip(steerChip);
          }
        });
      });
    });
  }

  /// Best-effort mapping from MoodChip → SteerChip for the radio
  /// hand-off (spec §2.3 row 2 "currently-selected MoodChip set" as
  /// initial steering vector). Maps the four chips that have a slice-5
  /// equivalent; Focus has no exact SteerChip cousin — we leave it
  /// unmapped, matching spec §2.3's "session captures the current
  /// multi-select set as its initial steering vector" via the
  /// chip-expression helper for chips that translate.
  static SteerChip? _toSteerChip(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return SteerChip.happier;
      case MoodChip.sad:
        return SteerChip.sadder;
      case MoodChip.chill:
        return SteerChip.calmer;
      case MoodChip.energetic:
        return SteerChip.moreIntense;
      case MoodChip.focus:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ...rest unchanged from Task 7's body, but reading state via
    // ref.watch directly...
    // (move the existing Build body in here verbatim, replacing
    // `ref.watch` calls with `ref.watch` against `ref` from
    // ConsumerState).
  }
}
```

Add the imports:

```dart
import 'package:prism_playlist_engine/playlist_engine.dart' show SteerChip;
import 'package:prism_playback/playback.dart' show QueueSnapshot, queueProvider;
import '../providers/radio_providers.dart';
```

- [ ] **Step 4: Run the test to verify pass**

Run: `cd apps/mobile && flutter test test/songs_shuffle_tab_test.dart`
Expected: PASS — Infinite ON + queue drained → startFromTrack fires.

- [ ] **Step 5: First-toast UX (slice 10 §7 risk 4)**

Add a one-shot toast on the first activation per session. After `startFromTrack` resolves in step 3, before applying chip steering, surface a `ScaffoldMessenger` snack:

```dart
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Infinite radio on — pulling more after this deck.'),
            duration: Duration(seconds: 3),
          ),
        );
```

(The "first activation" semantic is in-memory — `_radioRequested` already implements one-shot behaviour. Persistent first-toast across launches is out of scope; if needed later, drive from a `shared_preferences` flag.)

- [ ] **Step 6: Commit**

```bash
git add apps/mobile/lib/screens/songs_shuffle_tab.dart apps/mobile/test/songs_shuffle_tab_test.dart
git commit -m "mobile: Infinite toggle on Songs tab triggers radio at threshold

When Infinite is on and the queue drains to <=10 tracks, the most-
recently-played track seeds a fresh radio session via startFromTrack.
After the session boots, currently-selected MoodChips are translated
to SteerChip equivalents and applied as initial steering (Focus has no
slice-5 equivalent and is dropped per the locked steer vocabulary).

A one-shot snack surfaces 'Infinite radio on — pulling more after this
deck.' on first activation per session (spec §7 risk 4)."
```

---

## Phase E — Library sort + filter

### Task 13: `LibraryViewPrefs` value class + provider

The persistent state for Library's per-tab sort / filter / view-mode. shared_preferences-backed, async-init, exposed via `libraryViewPrefsProvider`. Default values applied immediately on first build; persisted choice replaces defaults once the SharedPreferences future resolves.

**Files:**
- Create: `apps/mobile/lib/providers/library_view_prefs.dart`
- Test: `apps/mobile/test/library_view_prefs_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/library_view_prefs_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile/providers/library_view_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults render before SharedPreferences resolves', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(libraryViewPrefsProvider);
    expect(state.albumSort, AlbumSort.title);
    expect(state.artistSort, ArtistSort.name);
    expect(state.playlistSort, PlaylistSort.createdDesc);
    expect(state.albumView, LibraryViewMode.grid);
    expect(state.artistView, LibraryViewMode.grid);
    expect(state.albumGenres, isEmpty);
    expect(state.artistGenres, isEmpty);
  });

  test('setting album sort persists across container rebuild', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumSort(AlbumSort.yearNewest);
    // The setter awaits SharedPreferences write; close & reopen.
    final reread = ProviderContainer();
    addTearDown(reread.dispose);
    // Pre-warm the future and then read state.
    await reread.read(libraryViewPrefsProvider.future);
    final state = reread.read(libraryViewPrefsProvider);
    expect(state.albumSort, AlbumSort.yearNewest);
  });

  test('genre filter list round-trips JSON-encoded', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumGenres(const ['rock', 'jazz']);
    final reread = ProviderContainer();
    addTearDown(reread.dispose);
    await reread.read(libraryViewPrefsProvider.future);
    final state = reread.read(libraryViewPrefsProvider);
    expect(state.albumGenres, equals(const ['rock', 'jazz']));
  });

  test('view-mode toggles persist', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumView(LibraryViewMode.list);
    final reread = ProviderContainer();
    addTearDown(reread.dispose);
    await reread.read(libraryViewPrefsProvider.future);
    expect(reread.read(libraryViewPrefsProvider).albumView,
        LibraryViewMode.list);
  });
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/library_view_prefs_test.dart`
Expected: FAIL — `library_view_prefs.dart` does not exist.

- [ ] **Step 3: Implement the provider + value class**

Create `apps/mobile/lib/providers/library_view_prefs.dart`:

```dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Album sort options surfaced in the filter sheet (spec §2.5 table).
enum AlbumSort { title, artist, yearNewest, yearOldest, recentlyAdded }

/// Artist sort options.
enum ArtistSort { name, albumCountDesc, recentlyAdded }

/// Playlist sort options. Slice 6 ships only Created (default) + Name.
enum PlaylistSort { createdDesc, name }

/// Per-tab grid/list toggle. Songs and Playlists are list-only; their
/// toggle is rendered disabled.
enum LibraryViewMode { grid, list }

class LibraryViewPrefs {
  final AlbumSort albumSort;
  final ArtistSort artistSort;
  final PlaylistSort playlistSort;
  final LibraryViewMode albumView;
  final LibraryViewMode artistView;
  final List<String> albumGenres;
  final List<String> artistGenres;

  const LibraryViewPrefs({
    this.albumSort = AlbumSort.title,
    this.artistSort = ArtistSort.name,
    this.playlistSort = PlaylistSort.createdDesc,
    this.albumView = LibraryViewMode.grid,
    this.artistView = LibraryViewMode.grid,
    this.albumGenres = const <String>[],
    this.artistGenres = const <String>[],
  });

  static const defaults = LibraryViewPrefs();

  LibraryViewPrefs copyWith({
    AlbumSort? albumSort,
    ArtistSort? artistSort,
    PlaylistSort? playlistSort,
    LibraryViewMode? albumView,
    LibraryViewMode? artistView,
    List<String>? albumGenres,
    List<String>? artistGenres,
  }) =>
      LibraryViewPrefs(
        albumSort: albumSort ?? this.albumSort,
        artistSort: artistSort ?? this.artistSort,
        playlistSort: playlistSort ?? this.playlistSort,
        albumView: albumView ?? this.albumView,
        artistView: artistView ?? this.artistView,
        albumGenres: albumGenres ?? this.albumGenres,
        artistGenres: artistGenres ?? this.artistGenres,
      );
}

/// Spec §2.5 SharedPreferences keys.
class LibraryViewPrefsKeys {
  LibraryViewPrefsKeys._();
  static const albumSort = 'library_sort_albums';
  static const artistSort = 'library_sort_artists';
  static const playlistSort = 'library_sort_playlists';
  static const albumView = 'library_view_albums';
  static const artistView = 'library_view_artists';
  static const albumGenres = 'library_filter_albums_genres';
  static const artistGenres = 'library_filter_artists_genres';
}

class LibraryViewPrefsNotifier extends AsyncNotifier<LibraryViewPrefs> {
  SharedPreferences? _prefs;

  @override
  Future<LibraryViewPrefs> build() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    return LibraryViewPrefs(
      albumSort: _enum(prefs.getString(LibraryViewPrefsKeys.albumSort),
          AlbumSort.values, AlbumSort.title),
      artistSort: _enum(prefs.getString(LibraryViewPrefsKeys.artistSort),
          ArtistSort.values, ArtistSort.name),
      playlistSort: _enum(prefs.getString(LibraryViewPrefsKeys.playlistSort),
          PlaylistSort.values, PlaylistSort.createdDesc),
      albumView: _enum(prefs.getString(LibraryViewPrefsKeys.albumView),
          LibraryViewMode.values, LibraryViewMode.grid),
      artistView: _enum(prefs.getString(LibraryViewPrefsKeys.artistView),
          LibraryViewMode.values, LibraryViewMode.grid),
      albumGenres: _decodeList(
          prefs.getString(LibraryViewPrefsKeys.albumGenres)),
      artistGenres: _decodeList(
          prefs.getString(LibraryViewPrefsKeys.artistGenres)),
    );
  }

  Future<void> setAlbumSort(AlbumSort value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.albumSort, value.name);
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(albumSort: value));
  }

  Future<void> setArtistSort(ArtistSort value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.artistSort, value.name);
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(artistSort: value));
  }

  Future<void> setPlaylistSort(PlaylistSort value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.playlistSort, value.name);
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(playlistSort: value));
  }

  Future<void> setAlbumView(LibraryViewMode value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.albumView, value.name);
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(albumView: value));
  }

  Future<void> setArtistView(LibraryViewMode value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.artistView, value.name);
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(artistView: value));
  }

  Future<void> setAlbumGenres(List<String> values) async {
    await _ensurePrefs();
    await _prefs!.setString(
        LibraryViewPrefsKeys.albumGenres, jsonEncode(values));
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(albumGenres: List.unmodifiable(values)));
  }

  Future<void> setArtistGenres(List<String> values) async {
    await _ensurePrefs();
    await _prefs!.setString(
        LibraryViewPrefsKeys.artistGenres, jsonEncode(values));
    state = AsyncValue.data((state.valueOrNull ?? LibraryViewPrefs.defaults)
        .copyWith(artistGenres: List.unmodifiable(values)));
  }

  Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static T _enum<T extends Enum>(String? raw, List<T> values, T fallback) {
    if (raw == null) return fallback;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }

  static List<String> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return List<String>.unmodifiable(
        decoded.whereType<String>(),
      );
    } catch (_) {
      return const <String>[];
    }
  }
}

final libraryViewPrefsProvider =
    AsyncNotifierProvider<LibraryViewPrefsNotifier, LibraryViewPrefs>(
  LibraryViewPrefsNotifier.new,
);
```

- [ ] **Step 4: Run the test**

Run: `cd apps/mobile && flutter test test/library_view_prefs_test.dart`
Expected: PASS.

> **Note on the first test ("defaults render before SharedPreferences resolves"):** the test as written reads `libraryViewPrefsProvider` synchronously and expects defaults. With `AsyncNotifierProvider`, the synchronous read returns `AsyncValue.loading()` initially. Adjust either (a) the test to call `valueOrNull ?? LibraryViewPrefs.defaults`, or (b) wrap the provider so the synchronous read always returns a `LibraryViewPrefs` (with defaults during loading). Option (b) is what the spec §7 risk 9 mitigation suggests — the simplest path is to expose a separate `libraryViewPrefsSyncProvider` that reads `valueOrNull ?? defaults`. Land option (b) and update the test accordingly.

Concretely, append to `library_view_prefs.dart`:

```dart
/// Synchronous accessor used by the Library UI. Returns defaults until
/// the async future resolves; persistence still happens asynchronously
/// via the underlying notifier.
final libraryViewPrefsSyncProvider = Provider<LibraryViewPrefs>((ref) {
  return ref.watch(libraryViewPrefsProvider).valueOrNull ??
      LibraryViewPrefs.defaults;
});
```

Update the test to read from `libraryViewPrefsSyncProvider` for the default-rendering case. Setter calls (`.notifier.setAlbumSort(...)`) still go through the AsyncNotifier.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/providers/library_view_prefs.dart apps/mobile/test/library_view_prefs_test.dart
git commit -m "mobile: LibraryViewPrefs (sort/filter/view-mode persistence)

shared_preferences-backed AsyncNotifier with per-tab sort, view-mode,
and genre-filter setters. libraryViewPrefsSyncProvider returns defaults
during the async load (spec §7 risk 9 mitigation: 'first build paints
unsorted/unfiltered' avoided). Genre lists JSON-encoded under the
spec §2.5 keys."
```

---

### Task 14: `genreOptionsProvider` — distinct, title-cased genres from `cache.db`

**Files:**
- Create: `apps/mobile/lib/providers/genre_options_provider.dart`
- Test: extend `apps/mobile/test/library_view_prefs_test.dart` (or create a separate test if cleaner)

- [ ] **Step 1: Write the failing test**

Append to `apps/mobile/test/library_view_prefs_test.dart` a new group:

```dart
  // ... at top of the file, add the import:
  // import 'package:mobile/providers/genre_options_provider.dart';

  group('GenreOptions value', () {
    test('title-cases display labels and dedupes by lower-case key', () {
      final raws = ['rock', 'Rock', 'ROCK', 'jazz', 'Lo-fi'];
      final options = GenreOption.collapseFromRaw(raws);
      expect(options.length, 3);
      expect(options.map((o) => o.label).toSet(),
          equals({'Rock', 'Jazz', 'Lo-fi'}));
      // Storage keys retain the original casings for SQL match.
      final rock = options.firstWhere((o) => o.label == 'Rock');
      expect(rock.storageKeys.toSet(), equals({'rock', 'Rock', 'ROCK'}));
    });
  });
```

- [ ] **Step 2: Implement `genre_options_provider.dart`**

Create `apps/mobile/lib/providers/genre_options_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cache_db_providers.dart';

/// One genre option for the filter sheet's multi-select. `label` is
/// title-cased for display; `storageKeys` is the set of original tag
/// strings that collapse to this label (used in the SQL `IN (...)`
/// clause when building the genre filter).
class GenreOption {
  final String label;
  final List<String> storageKeys;
  const GenreOption({required this.label, required this.storageKeys});

  /// Pure helper: collapses [raws] (raw tag values) into deduped
  /// `GenreOption` entries.
  static List<GenreOption> collapseFromRaw(Iterable<String> raws) {
    final byLower = <String, List<String>>{};
    final firstSeenForLower = <String, String>{};
    for (final raw in raws) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      byLower.putIfAbsent(lower, () => <String>[]).add(trimmed);
      firstSeenForLower.putIfAbsent(lower, () => trimmed);
    }
    final out = <GenreOption>[];
    final lowers = byLower.keys.toList()..sort();
    for (final lower in lowers) {
      final keys = byLower[lower]!;
      out.add(GenreOption(
        label: _titleCase(firstSeenForLower[lower]!),
        storageKeys: List<String>.unmodifiable(keys),
      ));
    }
    return List<GenreOption>.unmodifiable(out);
  }

  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return s
        .split(RegExp(r'(\s+|-)'))
        .map((w) => w.isEmpty
            ? w
            : (w == '-'
                ? '-'
                : '${w.substring(0, 1).toUpperCase()}${w.substring(1).toLowerCase()}'))
        .join();
  }
}

/// Distinct genre options from `cache.db` `tracks.genre`. Excludes null
/// / empty / 'unknown'. Sorted by lower-case label.
final genreOptionsProvider =
    FutureProvider<List<GenreOption>>((ref) async {
  final db = await ref.watch(cacheDbProvider.future);
  final rows = await db.writer.rawQuery('''
    SELECT DISTINCT genre FROM tracks
     WHERE status = 'ready' AND genre IS NOT NULL
  ''');
  final raws = <String>[];
  for (final r in rows) {
    final raw = (r['genre'] as String?)?.trim();
    if (raw == null || raw.isEmpty) continue;
    if (raw.toLowerCase() == 'unknown') continue;
    raws.add(raw);
  }
  return GenreOption.collapseFromRaw(raws);
});
```

- [ ] **Step 3: Run the test**

Run: `cd apps/mobile && flutter test test/library_view_prefs_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/mobile/lib/providers/genre_options_provider.dart apps/mobile/test/library_view_prefs_test.dart
git commit -m "mobile: genreOptionsProvider for the Library filter sheet

Reads DISTINCT non-null tracks.genre from cache.db (status='ready'),
collapses by lower-case key (so 'rock'/'Rock'/'ROCK' merge under one
'Rock' label), and surfaces a list of GenreOption with storage-key
sets. Title-cases the display label while preserving the original
casings for the SQL IN(...) clause."
```

---

### Task 15: `LibraryFilterSheet` (glass bottom sheet)

The sort + filter bottom sheet, contents driven by the active tab. Per-tab sort radio rows and a multi-select genre dropdown for Albums / Artists.

**Files:**
- Create: `apps/mobile/lib/widgets/library_filter_sheet.dart`

- [ ] **Step 1: Implement the sheet**

Create `apps/mobile/lib/widgets/library_filter_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/genre_options_provider.dart';
import '../providers/library_view_prefs.dart';

/// Tab identifier — drives the sheet's section selection.
enum LibrarySheetTab { albums, artists, playlists, songs }

/// Glass bottom-sheet hosting per-tab sort + filter controls. Spec §2.5
/// renders this with `Glass(intensity: heavy, radius: 24)`.
class LibraryFilterSheet extends ConsumerWidget {
  const LibraryFilterSheet({super.key, required this.tab});
  final LibrarySheetTab tab;

  static Future<void> show(BuildContext context, LibrarySheetTab tab) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => LibraryFilterSheet(tab: tab),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s4, tokens.s4),
        child: Glass(
          intensity: GlassIntensity.heavy,
          radius: 24,
          padding: EdgeInsets.all(tokens.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(_titleFor(tab), style: scale.display20),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _reset(ref, tab),
                    child: const Text('Reset'),
                  ),
                ],
              ),
              SizedBox(height: tokens.s2),
              ..._sortSection(ref, prefs, tokens, scale),
              if (tab == LibrarySheetTab.albums ||
                  tab == LibrarySheetTab.artists) ...[
                SizedBox(height: tokens.s4),
                _GenreSection(tab: tab),
              ],
              SizedBox(height: tokens.s4),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _titleFor(LibrarySheetTab tab) {
    switch (tab) {
      case LibrarySheetTab.albums:
        return 'Sort & filter albums';
      case LibrarySheetTab.artists:
        return 'Sort & filter artists';
      case LibrarySheetTab.playlists:
        return 'Sort playlists';
      case LibrarySheetTab.songs:
        return 'Songs';
    }
  }

  List<Widget> _sortSection(
    WidgetRef ref,
    LibraryViewPrefs prefs,
    SpaceTokens tokens,
    TypographyScale scale,
  ) {
    switch (tab) {
      case LibrarySheetTab.albums:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in AlbumSort.values)
            RadioListTile<AlbumSort>(
              value: v,
              groupValue: prefs.albumSort,
              title: Text(_albumSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setAlbumSort(value);
              },
            ),
        ];
      case LibrarySheetTab.artists:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in ArtistSort.values)
            RadioListTile<ArtistSort>(
              value: v,
              groupValue: prefs.artistSort,
              title: Text(_artistSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setArtistSort(value);
              },
            ),
        ];
      case LibrarySheetTab.playlists:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in PlaylistSort.values)
            RadioListTile<PlaylistSort>(
              value: v,
              groupValue: prefs.playlistSort,
              title: Text(_playlistSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setPlaylistSort(value);
              },
            ),
        ];
      case LibrarySheetTab.songs:
        return [
          Text(
            'Songs sort is driven by the chip row + tempo dropdown above.',
            style: scale.caption13,
          ),
        ];
    }
  }

  void _reset(WidgetRef ref, LibrarySheetTab tab) {
    final notifier = ref.read(libraryViewPrefsProvider.notifier);
    switch (tab) {
      case LibrarySheetTab.albums:
        // ignore: discarded_futures
        notifier.setAlbumSort(AlbumSort.title);
        // ignore: discarded_futures
        notifier.setAlbumGenres(const <String>[]);
      case LibrarySheetTab.artists:
        // ignore: discarded_futures
        notifier.setArtistSort(ArtistSort.name);
        // ignore: discarded_futures
        notifier.setArtistGenres(const <String>[]);
      case LibrarySheetTab.playlists:
        // ignore: discarded_futures
        notifier.setPlaylistSort(PlaylistSort.createdDesc);
      case LibrarySheetTab.songs:
        break;
    }
  }

  static String _albumSortLabel(AlbumSort v) {
    switch (v) {
      case AlbumSort.title:
        return 'Title';
      case AlbumSort.artist:
        return 'Artist';
      case AlbumSort.yearNewest:
        return 'Year (newest first)';
      case AlbumSort.yearOldest:
        return 'Year (oldest first)';
      case AlbumSort.recentlyAdded:
        return 'Recently added';
    }
  }

  static String _artistSortLabel(ArtistSort v) {
    switch (v) {
      case ArtistSort.name:
        return 'Name';
      case ArtistSort.albumCountDesc:
        return 'Album count (most first)';
      case ArtistSort.recentlyAdded:
        return 'Recently added';
    }
  }

  static String _playlistSortLabel(PlaylistSort v) {
    switch (v) {
      case PlaylistSort.createdDesc:
        return 'Created (newest first)';
      case PlaylistSort.name:
        return 'Name';
    }
  }
}

class _GenreSection extends ConsumerStatefulWidget {
  const _GenreSection({required this.tab});
  final LibrarySheetTab tab;
  @override
  ConsumerState<_GenreSection> createState() => _GenreSectionState();
}

class _GenreSectionState extends ConsumerState<_GenreSection> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final asyncOptions = ref.watch(genreOptionsProvider);
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    final selectedKeys = widget.tab == LibrarySheetTab.albums
        ? prefs.albumGenres
        : prefs.artistGenres;
    return asyncOptions.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: EdgeInsets.all(tokens.s2),
        child: Text('Genre list unavailable: $e',
            style: TextStyle(color: theme.colorScheme.error)),
      ),
      data: (options) {
        final showSearch = options.length > 50;
        final filtered = _filter.isEmpty
            ? options
            : options
                .where((o) =>
                    o.label.toLowerCase().contains(_filter.toLowerCase()))
                .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Genres (OR)', style: scale.caption13),
            if (showSearch) ...[
              SizedBox(height: tokens.s2),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search genres',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ],
            SizedBox(height: tokens.s2),
            Wrap(
              spacing: tokens.s2,
              runSpacing: tokens.s1,
              children: [
                for (final option in filtered)
                  FilterChip(
                    label: Text(option.label),
                    selected: option.storageKeys
                        .any((k) => selectedKeys.contains(k)),
                    onSelected: (selected) {
                      final next = List<String>.from(selectedKeys);
                      if (selected) {
                        for (final k in option.storageKeys) {
                          if (!next.contains(k)) next.add(k);
                        }
                      } else {
                        next.removeWhere(option.storageKeys.contains);
                      }
                      // ignore: discarded_futures
                      if (widget.tab == LibrarySheetTab.albums) {
                        ref
                            .read(libraryViewPrefsProvider.notifier)
                            .setAlbumGenres(next);
                      } else {
                        // ignore: discarded_futures
                        ref
                            .read(libraryViewPrefsProvider.notifier)
                            .setArtistGenres(next);
                      }
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/mobile/lib/widgets/library_filter_sheet.dart
git commit -m "mobile: LibraryFilterSheet — glass bottom sheet for sort + filter

Per-tab sort sections via RadioListTile; multi-select genre filter
(Albums + Artists) via FilterChip wrap with optional search field when
options > 50. Reset / Done buttons. Closes via the spec §7 risk 11
notifier flow once Library mounts the close-on-tab-change listener
(Task 16)."
```

---

### Task 16: Library header buttons + sort callbacks + filter wiring

This is the largest cleanup task. Adds the two glass square buttons next to the "Library" title (grid/list toggle + filter), wires them to the tab-aware sheet, parameterises `_AlbumsTab` / `_ArtistsTab` to honour sort + filter prefs, and adds the close-on-tab-change behaviour for the sheet.

**Files:**
- Modify: `apps/mobile/lib/screens/library_screen.dart`
- Modify: `apps/mobile/lib/browse/album_view.dart` (add a `sortAlbums(...)` helper)
- Modify: `apps/mobile/lib/browse/artist_view.dart` (add a `sortArtists(...)` helper)
- Test: `apps/mobile/test/library_sort_filter_test.dart` (new)

- [ ] **Step 1: Write the failing test file**

Create `apps/mobile/test/library_sort_filter_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/browse/artist_view.dart';
import 'package:mobile/providers/library_view_prefs.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/screens/library_screen.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Year (newest) reorders the album grid', (tester) async {
    final albums = <AlbumView>[
      const AlbumView(id: 'a∷Old', title: 'Old', artist: 'A', year: 2010, tracks: []),
      const AlbumView(id: 'a∷New', title: 'New', artist: 'A', year: 2024, tracks: []),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider.overrideWith((ref) => AsyncValue.data(albums)),
          artistsProvider.overrideWith((ref) => const AsyncValue.data([])),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Default sort = title; "New" comes before "Old" alphabetically.
    final beforeNew = tester.getCenter(find.text('New'));
    final beforeOld = tester.getCenter(find.text('Old'));
    expect(beforeNew.dy, lessThan(beforeOld.dy));

    // Swap to yearNewest via the notifier directly (sheet UI not under
    // test — exercised in widget test below).
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumSort(AlbumSort.yearNewest);
    await tester.pumpAndSettle();
    final afterNew = tester.getCenter(find.text('New'));
    final afterOld = tester.getCenter(find.text('Old'));
    expect(afterNew.dy, lessThan(afterOld.dy),
        reason: 'New (2024) should come before Old (2010) when sorted by year-newest');
  });

  testWidgets('genre filter shows only matching albums', (tester) async {
    final rockTrack = const Track(
        path: '/r.flac', mtimeMs: 0, title: 'R',
        artist: 'A', album: 'RA', genre: 'Rock');
    final jazzTrack = const Track(
        path: '/j.flac', mtimeMs: 0, title: 'J',
        artist: 'A', album: 'JA', genre: 'Jazz');
    final albums = <AlbumView>[
      AlbumView(id: 'a∷RA', title: 'RA', artist: 'A', tracks: [rockTrack]),
      AlbumView(id: 'a∷JA', title: 'JA', artist: 'A', tracks: [jazzTrack]),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider.overrideWith((ref) => AsyncValue.data(albums)),
          artistsProvider.overrideWith((ref) => const AsyncValue.data([])),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('RA'), findsOneWidget);
    expect(find.text('JA'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumGenres(const ['Rock']);
    await tester.pumpAndSettle();
    expect(find.text('RA'), findsOneWidget);
    expect(find.text('JA'), findsNothing);
  });

  testWidgets('view-mode toggle switches grid → list layout', (tester) async {
    final albums = <AlbumView>[
      const AlbumView(id: 'a∷RA', title: 'RA', artist: 'A', tracks: []),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider.overrideWith((ref) => AsyncValue.data(albums)),
          artistsProvider.overrideWith((ref) => const AsyncValue.data([])),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumView(LibraryViewMode.list);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `cd apps/mobile && flutter test test/library_sort_filter_test.dart`
Expected: FAIL — `LibraryScreen` has no sort/filter wiring yet.

- [ ] **Step 3: Add sort helpers to `album_view.dart` and `artist_view.dart`**

Append to `apps/mobile/lib/browse/album_view.dart`:

```dart
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
/// strings, case-sensitive — they're the actual tag values stored on
/// disk; matching to display labels happens at the sheet level).
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
```

Add the import at the top of `album_view.dart`:

```dart
import '../providers/library_view_prefs.dart';
```

Append to `apps/mobile/lib/browse/artist_view.dart`:

```dart
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
```

Add the import:

```dart
import '../providers/library_view_prefs.dart';
```

- [ ] **Step 4: Wire `LibraryScreen` to the prefs + filter sheet**

Edit `apps/mobile/lib/screens/library_screen.dart`. Replace the existing `LibraryScreen` body with:

```dart
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late final TabController? _ignored; // DefaultTabController owns the controller
  int _activeTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    // Existing slice-2 + slice-9 backfill kickoffs:
    // ignore: unused_result
    ref.watch(backfillKickoffProvider);
    // ignore: unused_result
    ref.watch(castProbeManualOnLaunchProvider);

    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    return DefaultTabController(
      length: 4,
      child: Builder(builder: (context) {
        final controller = DefaultTabController.of(context);
        controller.removeListener(_onTabChange);
        controller.addListener(_onTabChange);
        return AppShell(
          title: 'Library',
          currentTab: AppTab.library,
          useAurora: AuroraVariant.library,
          showAppBar: false,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s4, tokens.s4, tokens.s2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Library',
                          style: scale.display36.copyWith(
                            fontSize: 32,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.8,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      _ViewToggleButton(
                        prefs: prefs,
                        tab: _currentSheetTab(),
                      ),
                      SizedBox(width: tokens.s2),
                      _FilterButton(tab: _currentSheetTab()),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: tokens.s4),
                  child: const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Albums'),
                      Tab(text: 'Artists'),
                      Tab(text: 'Playlists'),
                      Tab(text: 'Songs'),
                    ],
                  ),
                ),
                const Expanded(
                  child: TabBarView(
                    children: [
                      _AlbumsTab(),
                      _ArtistsTab(),
                      _PlaylistsTab(),
                      _SongsTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  void _onTabChange() {
    final controller = DefaultTabController.of(context);
    if (!mounted) return;
    if (controller.indexIsChanging) {
      // Spec §7 risk 11: dismiss the sheet if open when tab changes.
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    setState(() => _activeTabIndex = controller.index);
  }

  LibrarySheetTab _currentSheetTab() {
    switch (_activeTabIndex) {
      case 0:
        return LibrarySheetTab.albums;
      case 1:
        return LibrarySheetTab.artists;
      case 2:
        return LibrarySheetTab.playlists;
      case 3:
      default:
        return LibrarySheetTab.songs;
    }
  }
}

class _ViewToggleButton extends ConsumerWidget {
  const _ViewToggleButton({required this.prefs, required this.tab});
  final LibraryViewPrefs prefs;
  final LibrarySheetTab tab;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isAlbum = tab == LibrarySheetTab.albums;
    final isArtist = tab == LibrarySheetTab.artists;
    final disabled = !(isAlbum || isArtist);
    final mode = isAlbum ? prefs.albumView : prefs.artistView;
    final iconNext = mode == LibraryViewMode.grid
        ? Icons.view_list_outlined
        : Icons.grid_view_outlined;
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: IconButton(
        tooltip: disabled ? 'Grid/list view (n/a)' : 'Grid/list view',
        icon: Icon(iconNext),
        onPressed: disabled
            ? null
            : () {
                final next = mode == LibraryViewMode.grid
                    ? LibraryViewMode.list
                    : LibraryViewMode.grid;
                if (isAlbum) {
                  // ignore: discarded_futures
                  ref
                      .read(libraryViewPrefsProvider.notifier)
                      .setAlbumView(next);
                } else if (isArtist) {
                  // ignore: discarded_futures
                  ref
                      .read(libraryViewPrefsProvider.notifier)
                      .setArtistView(next);
                }
              },
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.tab});
  final LibrarySheetTab tab;
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Filter',
      icon: const Icon(Icons.tune),
      onPressed: () => LibraryFilterSheet.show(context, tab),
    );
  }
}
```

Then update `_AlbumsTab` and `_ArtistsTab` to read prefs and apply sort + filter:

```dart
class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (albums) {
        final filtered = filterAlbumsByGenre(albums, prefs.albumGenres);
        final sorted = sortAlbums(filtered, prefs.albumSort);
        if (sorted.isEmpty) return const _EmptyTab(text: 'No albums match.');
        if (prefs.albumView == LibraryViewMode.grid) {
          return GridView.builder(
            padding: EdgeInsets.all(tokens.s4),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: tokens.s4,
              crossAxisSpacing: tokens.s4,
              childAspectRatio: 0.8,
            ),
            itemCount: sorted.length,
            itemBuilder: (_, i) => AlbumTile(
              album: sorted[i],
              onTap: () => Navigator.of(context).push(
                AlbumDetailScreen.route(sorted[i].id),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          itemCount: sorted.length,
          itemBuilder: (_, i) {
            final a = sorted[i];
            return ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: AlbumTile(album: a, onTap: () {}, size: 48),
              ),
              title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${a.artist} · ${a.tracks.length} tracks',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).push(
                AlbumDetailScreen.route(a.id),
              ),
            );
          },
        );
      },
    );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (artists) {
        final filtered = filterArtistsByGenre(artists, prefs.artistGenres);
        final sorted = sortArtists(filtered, prefs.artistSort);
        if (sorted.isEmpty) return const _EmptyTab(text: 'No artists match.');
        if (prefs.artistView == LibraryViewMode.grid) {
          return GridView.builder(
            padding: EdgeInsets.all(tokens.s4),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: tokens.s4,
              crossAxisSpacing: tokens.s4,
              childAspectRatio: 0.78,
            ),
            itemCount: sorted.length,
            itemBuilder: (_, i) => ArtistTile(
              artist: sorted[i],
              onTap: () => Navigator.of(context).push(
                ArtistDetailScreen.route(sorted[i].id),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          itemCount: sorted.length,
          itemBuilder: (_, i) {
            final a = sorted[i];
            return ListTile(
              leading: SizedBox(
                width: 40,
                height: 40,
                child: ArtistTile(artist: a, onTap: () {}),
              ),
              title: Text(a.name),
              subtitle: Text('${a.albumCount} albums · ${a.trackCount} tracks'),
              onTap: () => Navigator.of(context).push(
                ArtistDetailScreen.route(a.id),
              ),
            );
          },
        );
      },
    );
  }
}
```

Add the imports at the top of `library_screen.dart`:

```dart
import '../providers/library_view_prefs.dart';
import '../widgets/library_filter_sheet.dart';
```

- [ ] **Step 5: Run the test**

Run: `cd apps/mobile && flutter test test/library_sort_filter_test.dart`
Expected: PASS.

- [ ] **Step 6: Run the full mobile suite**

Run: `cd apps/mobile && flutter test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add apps/mobile/lib/screens/library_screen.dart apps/mobile/lib/browse/album_view.dart apps/mobile/lib/browse/artist_view.dart apps/mobile/test/library_sort_filter_test.dart
git commit -m "mobile: wire Library header sort + filter + view-mode

Two glass square buttons next to the Library title — grid/list toggle
(disabled on Songs/Playlists tabs at 50% opacity) and filter (opens
LibraryFilterSheet for the active tab). _AlbumsTab and _ArtistsTab now
apply prefs.albumSort/albumGenres + view-mode through new sortAlbums /
filterAlbumsByGenre helpers (and the artist equivalents). Sheet
auto-dismisses when DefaultTabController index changes (spec §7
risk 11)."
```

---

### Task 17: Pre-warm `libraryViewPrefsProvider` + album-grouping-v2 flag in main.dart

Spec §7 risk 9 — `LibraryViewPrefs` should be pre-warmed before `runApp` so the first Library build never paints unsorted/unfiltered. Spec §7 risk 8 — gate album-grouping-v2 on `shared_preferences` flag `album_grouping_v2_applied` so an in-flight Hero never observes the id transition.

**Files:**
- Modify: `apps/mobile/lib/main.dart`
- Modify: `apps/mobile/lib/providers/library_view_prefs.dart` (add the v2 flag setter)
- Modify: `apps/mobile/lib/browse/album_view.dart` (already shifts ids — the flag is consumed at startup to flush any in-flight detail screens)

- [ ] **Step 1: Add the flag handling in `main.dart`**

Edit `apps/mobile/lib/main.dart`. After `final container = ProviderContainer(...)` and before `runApp`, add:

```dart
  // Pre-warm Library prefs so the first build never paints unsorted /
  // unfiltered (spec §7 risk 9). The future resolves before runApp;
  // the sync provider then returns the persisted choice immediately.
  // ignore: unused_result
  await container.read(libraryViewPrefsProvider.future);

  // Spec §7 risk 8 — the album-grouping fix re-keys AlbumView.id between
  // releases for affected albums. Drop any persisted album-detail
  // back-stack entries on first launch after the fix lands so no
  // in-flight Hero observes the id transition.
  final prefs = await SharedPreferences.getInstance();
  const groupingFlag = 'album_grouping_v2_applied';
  if (!(prefs.getBool(groupingFlag) ?? false)) {
    // Pop any deep-link state that might have been restored.
    await prefs.setBool(groupingFlag, true);
    // No back-stack to clear before runApp — Flutter restores route
    // stacks lazily; the flag's job here is to record that we ran the
    // gate. Subsequent launches see groupingFlag=true and the new
    // canonical id is the only id ever observed.
  }
```

Add the imports:

```dart
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/library_view_prefs.dart';
```

- [ ] **Step 2: Run the slice-1 widget test to confirm the boot path still works**

Run: `cd apps/mobile && flutter test test/widget_test.dart`
Expected: PASS — the gear-icon walk uses `ProviderScope`, not the `main()` boot path; this step is a defensive run.

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/lib/main.dart
git commit -m "mobile: pre-warm libraryViewPrefsProvider; record grouping-v2 flag

Spec §7 risk 9 — pre-warm libraryViewPrefsProvider.future before runApp
so the first Library build paints with the persisted sort/filter
choice, never the loading default. Spec §7 risk 8 — record
album_grouping_v2_applied in shared_preferences on first launch so the
canonical-album-artist re-keying is observed only once per device."
```

---

## Phase F — Cleanup, route drops, test rewrite

### Task 18: Retire `VibeBrowseScreen`

The screen is no longer mounted (slice-9's wireframe pass already dropped it from `LibraryScreen`'s tab list, but the file is still present). Delete it; clean up the dangling `tempo_band_chips.dart` references inside `vibe_browse_screen.dart`. Leave `tempo_band_chips.dart` — it's still used by tests (`vibe_query_test.dart` references the `TempoBand` enum, which remains in `vibe_query.dart`); the widget itself has no other consumer after this slice.

**Files:**
- Delete: `apps/mobile/lib/screens/vibe_browse_screen.dart`
- Delete: `apps/mobile/lib/widgets/tempo_band_chips.dart` (only consumer was VibeBrowseScreen — verify with grep first)
- Modify: `apps/mobile/lib/screens/library_screen.dart` (drop the stale doc-comment reference)

- [ ] **Step 1: Confirm no other consumer of `tempo_band_chips.dart`**

Run a grep:
```
grep -rn 'tempo_band_chips\|TempoBandChips' /home/sanyo/Projects/music-player/apps /home/sanyo/Projects/music-player/packages
```

If only `vibe_browse_screen.dart` references it, delete it. If anything else does, leave the widget file in place.

- [ ] **Step 2: Delete the screen + widget files**

```bash
git rm apps/mobile/lib/screens/vibe_browse_screen.dart
# Conditional — only if step 1 found no other consumer:
git rm apps/mobile/lib/widgets/tempo_band_chips.dart
```

- [ ] **Step 3: Drop the stale doc-comment reference from library_screen.dart**

Edit `apps/mobile/lib/screens/library_screen.dart`. Replace the existing class doc-comment block (lines ~17–30) with a clean version that no longer mentions Random / Vibe sub-tabs:

```dart
/// 4-tab Library surface — Albums / Artists / Playlists / Songs.
/// Tab order is locked; the wireframe (`mobile-browse.jsx`) shows the
/// same four labels in the same order.
///
/// Per-tab affordances:
/// - Albums: 2-col grid (default) or 1-col list — toggled by the
///   header's view button. Sort + genre filter via the filter sheet.
/// - Artists: 3-col avatar grid (default) or 1-col list. Same
///   filter-sheet sort + genre filter.
/// - Playlists: rendered slice-6 sheet content; sort by Created
///   (newest, default) or Name.
/// - Songs: SongsShuffleTab — the iPod-shuffle surface (multi-select
///   MoodChipRow + tempo dropdown + True-Shuffle/Infinite toggles).
```

- [ ] **Step 4: Run analyze + tests**

```
flutter analyze
cd apps/mobile && flutter test
```

Expected: no analyze issues; all tests pass.

- [ ] **Step 5: Commit**

```bash
git commit -am "mobile: retire VibeBrowseScreen + tempo_band_chips

Library Songs tab is now the iPod-shuffle surface (Task 7). Vibe was
last mounted in slice-4; the wireframe-shell pass dropped it from the
tab list. This commit deletes the source files and cleans library_
screen.dart's doc-comment to match the four-tab reality."
```

---

### Task 19: Retire `RadioHomeCard` + `RadioSeedHeader`; clean up `queue_screen.dart`

`RadioHomeCard` was the slice-5 LRU card on Home; `RadioSeedHeader` was the slice-5 pill above QueueScreen's Upcoming list. Spec §3.3 retires both. The slice-5 long-press path remains the canonical entry point for radio sessions (slice-10 §7 risk 7).

**Files:**
- Delete: `apps/mobile/lib/widgets/radio_home_card.dart`
- Delete: `apps/mobile/lib/widgets/radio_seed_header.dart`
- Modify: `apps/mobile/lib/screens/queue_screen.dart` (drop the import + `SliverToBoxAdapter(child: RadioSeedHeader())` line)
- Modify: `apps/mobile/lib/providers/radio_providers.dart` (remove stale doc-comment references)
- Modify: `apps/mobile/lib/radio/recent_seeds_store.dart` (update top-of-file doc comment)

- [ ] **Step 1: Edit `queue_screen.dart` to remove the `RadioSeedHeader` mount**

Edit `apps/mobile/lib/screens/queue_screen.dart`. Remove the import:

```dart
import '../widgets/radio_seed_header.dart';
```

…and remove the `SliverToBoxAdapter(child: RadioSeedHeader())` entry (around line 158, between PlayNext and Upcoming sections). Replace with a small comment so the diff is readable:

```dart
        // Slice 10 — RadioSeedHeader retired; radio re-entry now flows
        // through long-press + the Songs-tab Infinite toggle (spec §7
        // risk 7). Upcoming header sits directly under PlayNext now.
```

- [ ] **Step 2: Delete the two widget files**

```bash
git rm apps/mobile/lib/widgets/radio_home_card.dart apps/mobile/lib/widgets/radio_seed_header.dart
```

- [ ] **Step 3: Clean up doc comments in `radio_providers.dart` and `recent_seeds_store.dart`**

Edit `apps/mobile/lib/providers/radio_providers.dart`. Replace the line referring to `RadioHomeCard`:

```
///   LRU of three seeds shown in `RadioHomeCard`.
```

…with:

```
///   LRU of three seeds — slice-10 retired the `RadioHomeCard` surface;
///   the store stays for slice-5 long-press re-entry semantics.
```

Same edit on the line referring to `RadioSeedHeader`:

```
/// `RadioSeedHeader`, `RadioHomeCard`'s active state) read this.
```

→

```
/// (`RadioBadge`, `SteerChipBar`) read this.
```

Edit `apps/mobile/lib/radio/recent_seeds_store.dart`. Replace `RadioHomeCard paginates through` with `RadioHomeCard, retired in slice 10, used to paginate through`.

- [ ] **Step 4: Run analyze + tests**

```
flutter analyze
cd apps/mobile && flutter test
```

Expected: no analyze issues; all tests pass — `recent_seeds_store_test.dart` still tests the underlying storage and is unaffected.

- [ ] **Step 5: Commit**

```bash
git commit -am "mobile: retire RadioHomeCard + RadioSeedHeader

Slice 10 §2.1 + §3.3 — both are retired discoverability surfaces.
Long-press track/album/artist remains the canonical radio entry point;
the new Songs-tab Infinite toggle (Task 12) and AI-Compose end-of-
playlist sheet (Task 11) add the slice-10 re-entry paths. queue_screen
loses the SliverToBoxAdapter(child: RadioSeedHeader()) line; doc
comments in radio_providers.dart + recent_seeds_store.dart updated."
```

---

### Task 20: Drop `/random` and `/vibe` routes from `app.dart`

Slice 9's wireframe pass already removed the route entries (per the pre-Task-11 state of `app.dart`, only `/now-playing`, `/queue`, and `NewVibeSheet.routeName` remain in addition to the four shell routes). This task is a search-and-confirm step: verify no `/random` / `/vibe` literal route strings are referenced anywhere in `apps/mobile/lib`. If found, remove them.

**Files:**
- Verify (and optionally edit): `apps/mobile/lib/app.dart`
- Verify: `apps/mobile/lib/shell/settings_library.dart`
- Verify: `apps/mobile/lib/screens/*.dart`

- [ ] **Step 1: Grep for stale route literals**

Run:
```
grep -rn "'/random'\|'/vibe'" /home/sanyo/Projects/music-player/apps/mobile
```

Expected output: no matches in `lib/`. If any test references a stale route, update it to a current one.

- [ ] **Step 2: Verify `settings_library.dart` is clean**

`settings_library.dart` already only references the cache-stats + re-scan ListTiles (per its current body). Spec §2.6 mentions "settings_library may also touch retired routes" — confirm by grep:

```
grep -n "Navigator\|Route\|routeName" /home/sanyo/Projects/music-player/apps/mobile/lib/shell/settings_library.dart
```

If any reference to `/random`, `/vibe`, `/queue`, or `/now-playing` surfaces, remove the offending line. (Per the file's current state, none should appear; this task is mostly defensive verification.)

- [ ] **Step 3: Commit (if any edits land)**

If no edits: skip the commit. If edits land:

```bash
git commit -am "mobile: drop stale /random and /vibe references

Slice 10 §2.6 sweep — no remaining references to retired routes in
apps/mobile/lib/."
```

---

### Task 21: Rewrite the gear-icon walk (`widget_test.dart`)

Replaces the brittle `find.text('Library')` Material-AppBar lookup with `find.byTooltip('Settings')`, walks every `AppTab.values` entry instead of hardcoding tab names, and verifies each lands on `SettingsScreen` after tap.

**Files:**
- Modify: `apps/mobile/test/widget_test.dart`

- [ ] **Step 1: Replace the test body**

Replace `apps/mobile/test/widget_test.dart`'s entirety with:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app.dart';
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/llm_providers.dart';
import 'package:mobile/shell/app_shell.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';

/// Slice 10 §2.6 rewrite — exercises the gear icon from every entry in
/// [AppTab.values] using `find.byTooltip('Settings')`. Source of truth
/// is the enum, so adding a new tab updates one place (the enum) and
/// the test follows.
void main() {
  testWidgets('Settings reachable via the gear icon from every top-level tab',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.down,
              detail: 'overridden in widget test',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
        ],
        child: const PrismApp(),
      ),
    );
    await tester.pump();

    for (final tab in AppTab.values) {
      // The shell's tab pills present BottomNavigation entries; tap by
      // the labeled tile. Each entry exposes its label as plain Text
      // inside the glass nav row.
      final routeName = _routeFor(tab);
      // Push the corresponding named route so the screen mounts.
      tester.element(find.byType(MaterialApp))
          .findAncestorWidgetOfExactType<MaterialApp>();
      // ignore: deprecated_member_use_from_same_package
      await tester.pumpWidget(_buildApp());
      await tester.pump();
      // Navigate by name so we don't depend on the exact icon set.
      await Navigator.of(
        tester.element(find.byType(PrismApp)),
      ).pushReplacementNamed(routeName);
      await tester.pump();
      // The gear icon's tooltip is the source of truth (slice 10 §2.6).
      expect(
        find.byTooltip('Settings'),
        findsOneWidget,
        reason: 'Tab "$tab" must surface a Settings affordance',
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
      // Pop back to the tab so the next iteration starts clean.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }
  });
}

String _routeFor(AppTab tab) {
  switch (tab) {
    case AppTab.home:
      return AppShell.homeRoute;
    case AppTab.search:
      return AppShell.searchRoute;
    case AppTab.library:
      return AppShell.libraryRoute;
    case AppTab.ai:
      return AppShell.aiRoute;
  }
}

Widget _buildApp() => ProviderScope(
      overrides: [
        ollamaHealthProvider.overrideWith((ref) async* {
          yield const OllamaHealth(
            status: OllamaHealthStatus.down,
            detail: 'overridden in widget test',
          );
        }),
        castDiscoveryProvider.overrideWith(
          (ref) => const Stream<List<DlnaDevice>>.empty(),
        ),
      ],
      child: const PrismApp(),
    );
```

> **Note:** the screens that don't render a `Settings` gear (e.g. `HomeScreen` uses `showAppBar: false` and has no inline gear) need the test's expectation adjusted. Two reasonable options:
> - Have the test assert `findsAny` rather than `findsOneWidget` for tabs that show the icon as a header action vs. a body link, or
> - Add a small inline "Settings" affordance to each main tab's body (a glass square button matching the wireframe's "Library" header pattern from §2.5).
>
> The spec §2.6 requirement is "the gear is reachable, taps it, verifies SettingsScreen lands". The cleanest implementation lifts a small `SettingsButton` into AppShell that's always available — either in the AppBar (when `showAppBar: true`) or as a glass round button next to each tab's custom typographic header. Pick the one your design taste prefers; the test then asserts `findsOneWidget` consistently.

If you go with the `SettingsButton` lift: add it to `app_shell.dart` as a `Tooltip(message: 'Settings', child: ...)` rendered in the row alongside each tab's custom header, OR — simpler — keep `showAppBar: true` for all four tabs but style the AppBar transparently. The latter is the smaller patch.

- [ ] **Step 2: Run the rewritten test**

Run: `cd apps/mobile && flutter test test/widget_test.dart`
Expected: PASS for all four tabs.

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/test/widget_test.dart apps/mobile/lib/shell/app_shell.dart
git commit -m "mobile: rewrite gear-icon walk against AppTab.values + byTooltip

Slice 10 §2.6 — the test no longer asserts find.text('Library') (slice-1
Material AppBar artefact); instead it iterates AppTab.values and
expects find.byTooltip('Settings') under each tab's shell. Adding a
new top-level tab updates the enum and the test follows automatically.
A small SettingsButton lift into AppShell ensures every tab surfaces
the affordance regardless of showAppBar setting."
```

---

### Task 22: Final analyze + full-test sweep

End-to-end verification before merge. Runs `flutter analyze` then every dart/flutter test in the repo.

- [ ] **Step 1: `flutter analyze`**

Run from repo root: `flutter analyze`
Expected: no issues.

- [ ] **Step 2: Pure-Dart core tests**

Run: `cd packages/core && dart test`
Expected: all tests pass — slice-4 mood / vibe / migration / ingest tests + new slice-10 `vibe_shuffle_query_test.dart`.

- [ ] **Step 3: Pure-Dart playlist engine tests**

Run: `cd packages/playlist_engine && dart test`
Expected: all tests pass — slice-5 + slice-6 tests + new slice-10 `averageEmbeddings` and `ClusterSeed` groups.

- [ ] **Step 4: Mobile widget + integration tests**

Run: `cd apps/mobile && flutter test`
Expected: all tests pass — including the full slice-10 set:
- `songs_shuffle_tab_test.dart`
- `now_playing_radio_visibility_test.dart`
- `discover_grids_test.dart`
- `widget_test.dart` (rewritten)
- `radio_cluster_seed_test.dart`
- `album_grouping_test.dart`
- `library_view_prefs_test.dart`
- `library_sort_filter_test.dart`

…plus the surviving slice-1..9 tests:
- `backfill_queue_test.dart`
- `browse_providers_test.dart`
- `model_download_card_test.dart`
- `mood_chip_row_test.dart`
- `recent_seeds_store_test.dart`
- `steer_chip_bar_test.dart`

- [ ] **Step 5: Cross-package playback tests**

Run: `cd packages/playback && dart test`
Expected: all tests pass — playback service / queue service tests are slice-1 era and unaffected by slice 10.

- [ ] **Step 6: Final commit (only if any cleanup landed in this task)**

If any analyzer findings or test surprises surface and require fixes, fix them before claiming the slice is done. The fix lands in a final commit:

```bash
git commit -am "slice-10: final analyze + test pass

End-to-end verification — all dart/flutter tests pass; flutter analyze
shows no issues."
```

---

## Self-review pass

Reviewing the plan against the spec one more time:

**Spec §2.1 (Discover Home):** Task 8 lifts `RandomTab` into `DiscoverAlbumsGrid` + `DiscoverArtistsGrid`. Inserted between Featured and Artists rows in HomeScreen. Independent seeds preserved via separate `_seed` ints with mixed-in entropy constant. ✅

**Spec §2.2 (Vibe-steered Songs tab):** Task 4 builds `VibeShuffleQuery` (three modes via chip count + true-shuffle override; tempo band ANDs in; `LIMIT 1000` cap). Task 5 lifts `MoodChipController` to support multi-select. Task 7 builds `SongsShuffleTab` consuming both. Task 18 retires `VibeBrowseScreen`. ✅

**Spec §2.3 (Radio-aware NowPlaying):** Task 9 adds parent-layout guard + glass-pill restyle. Task 10 adds `startFromCluster` (new `ClusterSeed` from Task 2 + `averageEmbeddings` from Task 2). Task 11 adds the end-of-playlist sheet + `aiComposePlaybackProvider`. Task 12 wires the Infinite-toggle lookahead trigger. Three-stage chip hand-off (Songs MoodChipRow → session start → SteerChipBar) implemented in Task 12 step 3 via the `_toSteerChip` mapping. ✅

**Spec §2.4 (Album-grouping bug fix):** Task 6 — two-pass `indexAlbums` + `_normalizeArtist`. Track.albumArtist never mutated. ✅

**Spec §2.5 (Library sort + filter):** Task 13 LibraryViewPrefs. Task 14 genreOptionsProvider. Task 15 LibraryFilterSheet. Task 16 wires the header buttons + sort callbacks + filter sheet. Task 17 pre-warms prefs in main.dart. Per-tab options: Albums (5 sorts + genre filter), Artists (3 sorts + genre filter), Playlists (2 sorts), Songs (n/a — chips drive). View-mode toggle disabled on Songs/Playlists at 50% opacity. Genre filter is OR-of-genres; storage keys retain raw casings, display labels title-cased. Inline search field appears when options > 50. ✅

**Spec §2.6 (Test fix):** Task 21 rewrites the gear-icon walk against `AppTab.values + find.byTooltip('Settings')`. Task 20 confirms no stale `/random` or `/vibe` routes. ✅

**Spec §6 (9 test files):** Verified inline — every test the spec lists has its task pairing.

**Locked invariants:** Slice-4 SQL byte-identical (Task 1 = pure extraction, mood_query_test.dart unchanged). Slice-5 RadioSession state machine byte-identical (Task 2 only extends the SeedRef sealed family — no transition changes). Slice-7 theme tokens consumed only (Glass/Aurora/SpaceTokens never modified). MoodChip enum order preserved (Task 5's MoodChipController.visualOrder lookup reuses the existing list).

The plan covers every spec sub-section with specific files, paths, and step-by-step instructions. Each task has its test pair, verification command, and commit boundary.

---

## Plan complete — execution choice

**Plan complete and saved to `docs/plans/slice-10-wireframe-shell-implementation.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, with two-stage review between tasks. Best when the engineer is unfamiliar with the codebase or when each task's success criteria need verification before moving on.

**2. Inline Execution** — Execute tasks sequentially in this session via `superpowers:executing-plans`. Faster overall; less protective against drift between tasks.

Awaiting approval before any code is written.
