import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/steer_chip_bar.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

/// Slice 5 §11 item 7 + §2 — locked vocabulary (10 chips, fixed
/// visual order); tap `faster` clears `slower` within one
/// AnimatedSwitcher frame; mutual-exclusion fires for all four pairs.
///
/// The widget is exercised through Riverpod overrides so we don't
/// need a real CacheDb / playlist repo — `radioSessionProvider` is
/// overridden with [_FakeSessionNotifier], which echoes its initial
/// session and applies `withChipToggled` / `withChipCleared` purely
/// in memory.
void main() {
  group('SteerChipBar', () {
    test('locked visual order matches slice 5 §2 (Mood/Tempo/Era/Texture)',
        () {
      expect(SteerChipBar.visualOrder, [
        SteerChip.happier,
        SteerChip.sadder,
        SteerChip.calmer,
        SteerChip.moreIntense,
        SteerChip.slower,
        SteerChip.faster,
        SteerChip.newer,
        SteerChip.older,
        SteerChip.moreLikeThisArtist,
        SteerChip.differentArtists,
      ]);
      expect(SteerChipBar.visualOrder.length, equals(10));
    });

    test('kChipConflicts covers all four opposing pairs (mutual exclusion)',
        () {
      const expectedPairs = <(SteerChip, SteerChip)>{
        (SteerChip.calmer, SteerChip.moreIntense),
        (SteerChip.moreIntense, SteerChip.calmer),
        (SteerChip.slower, SteerChip.faster),
        (SteerChip.faster, SteerChip.slower),
        (SteerChip.newer, SteerChip.older),
        (SteerChip.older, SteerChip.newer),
        (SteerChip.moreLikeThisArtist, SteerChip.differentArtists),
        (SteerChip.differentArtists, SteerChip.moreLikeThisArtist),
      };
      final actual =
          kChipConflicts.entries.map((e) => (e.key, e.value)).toSet();
      expect(actual, equals(expectedPairs));
    });

    testWidgets('renders 10 chips when a session is active', (tester) async {
      // Widen the test viewport so all 10 chips materialize. The
      // SteerChipBar uses a horizontal ListView whose itemBuilder is
      // lazy — at the default 800 px viewport only ~5 chips paint.
      await tester.binding.setSurfaceSize(const Size(2400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            radioSessionProvider.overrideWith(_FakeSessionNotifier.new),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(body: SteerChipBar()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(FilterChip),
        findsNWidgets(10),
        reason: 'slice 5 §2 locks the steer chip count at exactly 10',
      );
    });

    testWidgets('SizedBox.shrink when no session is running',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            radioSessionProvider
                .overrideWith(() => _FakeSessionNotifier(initial: null)),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(body: SteerChipBar()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('tapping `faster` clears `slower` within the next frame',
        (tester) async {
      // Wide viewport so every chip materializes — without this only
      // the first ~5 chips lay out in the horizontal ListView and
      // `Faster` (index 5) sits offscreen.
      await tester.binding.setSurfaceSize(const Size(2400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final initial = _seedSession(active: SteerChip.slower);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            radioSessionProvider
                .overrideWith(() => _FakeSessionNotifier(initial: initial)),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(body: SteerChipBar()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sanity: slower is selected, faster is not.
      _expectChipSelected(tester, label: 'Slower', selected: true);
      _expectChipSelected(tester, label: 'Faster', selected: false);

      await tester.tap(find.text('Faster'));
      // Toggle propagates synchronously; one pump rebuilds the bar.
      await tester.pump();
      // AnimatedSwitcher's default duration is 250 ms.
      await tester.pump(const Duration(milliseconds: 260));

      _expectChipSelected(tester,
          label: 'Slower',
          selected: false,
          reason: 'kChipConflicts forces slower → cleared on faster tap');
      _expectChipSelected(tester, label: 'Faster', selected: true);
    });

    test('mutual exclusion fires for every opposing pair (engine semantics)',
        () {
      // Engine-level invariant — UI defers to it. We replay each side
      // of every pair through `withChipToggled` and verify the
      // opposite slot clears.
      for (final pair in const <(SteerChip, SteerChip)>[
        (SteerChip.calmer, SteerChip.moreIntense),
        (SteerChip.slower, SteerChip.faster),
        (SteerChip.newer, SteerChip.older),
        (SteerChip.moreLikeThisArtist, SteerChip.differentArtists),
      ]) {
        final initial = _seedSession(active: pair.$1);
        final after = initial.withChipToggled(pair.$2);
        expect(after.chips.containsKey(pair.$1), isFalse,
            reason:
                '${pair.$2} must clear ${pair.$1} (kChipConflicts symmetry)');
        expect(after.chips[pair.$2]?.isActive, isTrue);
      }
    });
  });
}

void _expectChipSelected(
  WidgetTester tester, {
  required String label,
  required bool selected,
  String? reason,
}) {
  final chip = tester.widget<FilterChip>(
    find.ancestor(of: find.text(label), matching: find.byType(FilterChip)),
  );
  expect(chip.selected, equals(selected), reason: reason);
}

RadioSession _seedSession({SteerChip? active}) {
  final embedding = Float32List(8);
  final base = RadioSession(
    seed: const TrackSeed(trackId: 1, title: 'Seed'),
    seedEmbedding: embedding,
  );
  if (active == null) return base;
  return base.withChipToggled(active);
}

/// In-memory stand-in for `RadioSessionNotifier`. Only the methods the
/// SteerChipBar reads are functional; the start* / stop methods are
/// no-ops because tapping a chip never touches them.
class _FakeSessionNotifier extends RadioSessionNotifier {
  /// When constructed with no [initial] argument, the fake builds a
  /// default seeded session so widget tests can hit the active path
  /// without setup. Pass `initial: null` explicitly to test the
  /// "no session" branch — the [forceNull] flag distinguishes the
  /// sentinel from "use default".
  _FakeSessionNotifier({this.initial = _SessionMarker.unset});

  /// Marker for the constructor — `null` is a valid in-band value
  /// (means "no session"), so we use a sentinel for "caller didn't
  /// provide one".
  static const Object _unset = _SessionMarker.unset;

  /// `_SessionMarker.unset` (default) → build a seeded session.
  /// `null` → build a null state (no radio).
  /// Any [RadioSession] → use it verbatim.
  final Object? initial;

  @override
  RadioSession? build() {
    if (identical(initial, _unset)) return _seedSession();
    return initial as RadioSession?;
  }

  // Override start* to no-ops so the radioSessionProvider fake doesn't
  // try to resolve the playlist repo (which would fail in tests).
  @override
  Future<void> startFromTrack(track) async {}

  @override
  Future<void> startFromAlbum({
    required String albumKey,
    required String title,
  }) async {}

  @override
  Future<void> startFromArtist({
    required String artist,
    required String label,
  }) async {}

  @override
  Future<void> toggleChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    state = current.withChipToggled(chip);
  }

  @override
  Future<void> clearChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    state = current.withChipCleared(chip);
  }

  @override
  Future<void> stop() async {
    state = null;
  }
}

/// Sentinel for "caller didn't pass an initial value" so we can
/// distinguish the explicit `null` case (no session) from "use
/// default seed".
enum _SessionMarker { unset }
