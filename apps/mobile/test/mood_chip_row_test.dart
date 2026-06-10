import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/mood_chip_row.dart';
import 'package:prism_core/core.dart';

void main() {
  group('MoodChipRow', () {
    testWidgets('renders five chips in locked order Happy/Sad/Chill/Energetic/Focus',
        (tester) async {
      // Slice 7 — every consumer reads SpaceTokens / TypographyScale
      // from `Theme.of(context).extension<...>()!`. The test wraps in
      // `PrismTheme.light()` so the extensions land in `ThemeData`.
      await tester.pumpWidget(
        MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: MoodChipRow()),
        ),
      );
      await tester.pumpAndSettle();

      // The visualOrder list is the locked source of truth — assert it
      // first so a future drift in the constant is caught loudly.
      expect(MoodChipRow.visualOrder, [
        MoodChip.happy,
        MoodChip.sad,
        MoodChip.chill,
        MoodChip.energetic,
        MoodChip.focus,
      ]);

      // FilterChips render their text label as descendants of each
      // chip; we sample the on-screen text in left-to-right order.
      final chipFinders = find.byType(FilterChip);
      expect(chipFinders, findsNWidgets(5));

      const labels = ['Happy', 'Sad', 'Chill', 'Energetic', 'Focus'];
      for (final label in labels) {
        expect(
          find.descendant(
            of: chipFinders,
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: 'expected chip label "$label" to be present',
        );
      }
    });

    testWidgets('multi-select toggles a chip into the controller set',
        (tester) async {
      var selection = <MoodChip>{};

      // Helper: rebuild the widget with a fresh controller carrying the
      // current selection. Mirrors the production "parent owns state"
      // pattern — taps emit a new Set, the parent updates state, the
      // next rebuild constructs a fresh controller with that state.
      Future<void> pump() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: PrismTheme.light(),
            home: Scaffold(
              body: MoodChipRow(
                controller: MoodChipController.multi(
                  initial: selection,
                  onChanged: (next) => selection = next,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      await tester.tap(find.text('Chill'));
      await tester.pumpAndSettle();
      expect(selection, equals(<MoodChip>{MoodChip.chill}));

      await pump();
      await tester.tap(find.text('Focus'));
      await tester.pumpAndSettle();
      expect(selection, equals(<MoodChip>{MoodChip.chill, MoodChip.focus}));

      await pump();
      await tester.tap(find.text('Chill'));
      await tester.pumpAndSettle();
      expect(selection, equals(<MoodChip>{MoodChip.focus}));
    });

    testWidgets('single-select default fires onTap when provided',
        (tester) async {
      // Slice-11 §C1 — single-mode no longer pushes a hardcoded route
      // (the old MoodResultsScreen target was retired). It now fires
      // the optional [onTap] callback so callers can decide what
      // happens (or wire nothing for a read-only render).
      MoodChip? tapped;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: Scaffold(
              body: MoodChipRow(
                controller: MoodChipController.single(
                  onTap: (chip) => tapped = chip,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Happy'));
      await tester.pump();
      expect(tapped, MoodChip.happy,
          reason: 'single-mode tap forwards the chip to onTap');
    });
  });
}
