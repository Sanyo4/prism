import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile/providers/library_view_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults render via libraryViewPrefsSyncProvider before SharedPreferences resolves', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(libraryViewPrefsSyncProvider);
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
    final state = reread.read(libraryViewPrefsProvider).asData!.value;
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
    final state = reread.read(libraryViewPrefsProvider).asData!.value;
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
    expect(reread.read(libraryViewPrefsProvider).asData!.value.albumView,
        LibraryViewMode.list);
  });
}
