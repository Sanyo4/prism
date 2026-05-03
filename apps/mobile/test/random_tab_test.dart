import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/browse/album_view.dart';
import 'package:mobile/browse/artist_view.dart';
import 'package:mobile/providers/metadata_providers.dart';
import 'package:mobile/screens/random_tab.dart';
import 'package:mobile/theme/prism_theme.dart';

void main() {
  testWidgets('RandomTab renders 6 albums and 6 artists', (tester) async {
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
          home: const Scaffold(body: RandomTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Six AlbumTiles + six ArtistTiles. (We can't filter by widget type
    // because tiles are private; assert by tap-target count via text.)
    final albumTitles = find.textContaining('Album ');
    expect(albumTitles, findsNWidgets(6));

    final artistNames = find.textContaining('Artist ');
    // Each ArtistTile renders a name; six expected.
    expect(artistNames, findsNWidgets(6));
  });

  testWidgets(
      'per-section refresh changes only that section (independent seeds)',
      (tester) async {
    final albums = _fixtureAlbums(20);
    final artists = _fixtureArtists(20);
    // Tall surface so both section headers (and their refresh buttons)
    // render in the same frame — RandomTab's outer ListView eagerly
    // builds, but the album grid + artist row need vertical room.
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
          home: const Scaffold(body: RandomTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Capture initial album titles + artist names.
    final initialAlbumTitles = _visibleTitlesContaining(tester, 'Album ');
    final initialArtistNames = _visibleTitlesContaining(tester, 'Artist ');

    // Tap the album-section refresh and pump.
    final refreshButtons = find.byTooltip('Refresh');
    expect(refreshButtons, findsNWidgets(2),
        reason: 'two refresh affordances — one per section');
    await tester.tap(refreshButtons.first);
    await tester.pumpAndSettle();
    final afterAlbumRefresh = _visibleTitlesContaining(tester, 'Album ');
    final unchangedArtists = _visibleTitlesContaining(tester, 'Artist ');

    // Albums almost certainly differ; artists must be identical.
    expect(unchangedArtists, equals(initialArtistNames),
        reason: 'artist seed must not change when albums refresh');
    // Probability all 6 collide is ~1/(20 choose 6) ≈ tiny; OK to assert.
    expect(afterAlbumRefresh, isNot(equals(initialAlbumTitles)),
        reason: 'album seed should produce a different ordering');
  });
}

List<String> _visibleTitlesContaining(WidgetTester tester, String prefix) {
  final finder = find.byWidgetPredicate(
    (w) => w is Text && (w.data?.contains(prefix) ?? false),
  );
  return finder
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
