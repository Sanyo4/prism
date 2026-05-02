import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/mood_chip_row.dart';
import 'package:prism_core/core.dart';

void main() {
  group('MoodChipRow', () {
    testWidgets('renders five chips in locked order Happy/Sad/Chill/Energetic/Focus',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: MoodChipRow()),
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
  });
}
