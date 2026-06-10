/// Slice-10b §C1 — widget tests for [BackfillProgressCard].
///
/// The three cases:
///   1. Provider yields null → card returns SizedBox.shrink (no progress bar).
///   2. Provider yields an in-progress snapshot → bar, counts, track name,
///      Cancel button visible.
///   3. Provider yields a completed snapshot → "Metadata updated" shown,
///      Cancel hidden.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/backfill/backfill_queue.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/backfill_progress_card.dart';

void main() {
  testWidgets('BackfillProgressCard hides when no progress', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backfillProgressProvider.overrideWith((ref) async* {
            yield null;
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: BackfillProgressCard()),
        ),
      ),
    );
    await tester.pump();
    // SizedBox.shrink — no LinearProgressIndicator in tree.
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('BackfillProgressCard renders progress bar + counts',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backfillProgressProvider.overrideWith((ref) async* {
            yield const BackfillProgress(
              total: 10,
              processed: 4,
              currentTrackTitle: 'Test Track',
            );
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: BackfillProgressCard()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('4 / 10 tracks'), findsOneWidget);
    expect(find.text('Enriching: Test Track'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('BackfillProgressCard shows "Metadata updated" on completion',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backfillProgressProvider.overrideWith((ref) async* {
            yield const BackfillProgress(
              total: 10,
              processed: 10,
            );
          }),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const Scaffold(body: BackfillProgressCard()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Metadata updated'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
  });
}
