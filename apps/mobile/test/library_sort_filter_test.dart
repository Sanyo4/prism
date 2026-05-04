import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/providers/library_view_prefs.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/screens/library_screen.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:prism_core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Year (newest) reorders the album grid', (tester) async {
    // "Alpha" (2010) alphabetically precedes "Zeta" (2024).
    // Title sort → Alpha at index 0 (smaller dx in 2-col row).
    // yearNewest sort → Zeta (2024) at index 0 (dx smaller than Alpha).
    final albums = <AlbumView>[
      const AlbumView(id: 'a∷Alpha', title: 'Alpha', artist: 'A', year: 2010, tracks: []),
      const AlbumView(id: 'a∷Zeta', title: 'Zeta', artist: 'A', year: 2024, tracks: []),
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
    // Default sort = title; "Alpha" comes before "Zeta" alphabetically.
    // Both fit in the same 2-col row — compare horizontal (dx).
    final beforeAlpha = tester.getCenter(find.text('Alpha'));
    final beforeZeta = tester.getCenter(find.text('Zeta'));
    expect(beforeAlpha.dx, lessThan(beforeZeta.dx),
        reason: 'alphabetically Alpha < Zeta, so Alpha is column 0 (smaller dx)');

    // Swap to yearNewest via the notifier directly.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
    await container
        .read(libraryViewPrefsProvider.notifier)
        .setAlbumSort(AlbumSort.yearNewest);
    await tester.pumpAndSettle();
    final afterAlpha = tester.getCenter(find.text('Alpha'));
    final afterZeta = tester.getCenter(find.text('Zeta'));
    expect(afterZeta.dx, lessThan(afterAlpha.dx),
        reason: 'Zeta (2024) should come before Alpha (2010) when sorted by year-newest');
  });

  testWidgets('genre filter shows only matching albums', (tester) async {
    const rockTrack = Track(
        path: '/r.flac', mtimeMs: 0, title: 'R',
        artist: 'A', album: 'RA', genre: 'Rock');
    const jazzTrack = Track(
        path: '/j.flac', mtimeMs: 0, title: 'J',
        artist: 'A', album: 'JA', genre: 'Jazz');
    final albums = <AlbumView>[
      const AlbumView(id: 'a∷RA', title: 'RA', artist: 'A', tracks: [rockTrack]),
      const AlbumView(id: 'a∷JA', title: 'JA', artist: 'A', tracks: [jazzTrack]),
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
