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
