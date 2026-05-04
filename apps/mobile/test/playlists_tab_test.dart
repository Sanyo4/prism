import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/browse/artist_view.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/providers/playlists_provider.dart';
import 'package:mobile/screens/library_screen.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

PlaylistRecord _record({
  int id = 1,
  String title = 'Test Playlist',
  List<String> tracks = const ['/a.flac', '/b.flac'],
  DateTime? createdAt,
}) {
  final created = createdAt ?? DateTime(2026, 1, 1);
  return PlaylistRecord(
    id: id,
    title: title,
    blurb: null,
    prompt: null,
    createdAt: created,
    updatedAt: created,
    trackPaths: tracks,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Playlists tab empty state', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider
              .overrideWith((ref) => const AsyncValue.data(<AlbumView>[])),
          artistsProvider
              .overrideWith((ref) => const AsyncValue.data(<ArtistView>[])),
          playlistsProvider
              .overrideWith((ref) async => const <PlaylistRecord>[]),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Navigate to Playlists tab (index 2) via the controller to avoid
    // the DefaultTabController.of(context) assertion that fires when
    // _onTabChange uses the outer state context.
    final tabController = DefaultTabController.of(
      tester.element(find.byType(TabBar)),
    );
    tabController.animateTo(2);
    await tester.pumpAndSettle();

    expect(find.text('No playlists yet.'), findsOneWidget);
  });

  testWidgets('Playlists tab renders rows from provider', (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final fixtures = <PlaylistRecord>[
      _record(id: 1, title: 'Rainy Sunday', createdAt: DateTime(2026, 4, 1)),
      _record(id: 2, title: 'Workout pump', createdAt: DateTime(2026, 5, 1)),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          albumsProvider
              .overrideWith((ref) => const AsyncValue.data(<AlbumView>[])),
          artistsProvider
              .overrideWith((ref) => const AsyncValue.data(<ArtistView>[])),
          playlistsProvider.overrideWith((ref) async => fixtures),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Navigate to Playlists tab (index 2) via the controller.
    final tabController = DefaultTabController.of(
      tester.element(find.byType(TabBar)),
    );
    tabController.animateTo(2);
    await tester.pumpAndSettle();

    // Newest first by default (createdDesc) — Workout pump (May) should appear
    // above Rainy Sunday (April).
    expect(find.text('Workout pump'), findsOneWidget);
    expect(find.text('Rainy Sunday'), findsOneWidget);

    final workoutPos = tester.getCenter(find.text('Workout pump')).dy;
    final rainyPos = tester.getCenter(find.text('Rainy Sunday')).dy;
    expect(workoutPos, lessThan(rainyPos),
        reason:
            'Workout pump (2026-05-01) is newer so it sorts above Rainy Sunday (2026-04-01)');
  });
}
