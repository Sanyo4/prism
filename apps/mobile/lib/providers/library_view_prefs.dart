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
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(albumSort: value));
  }

  Future<void> setArtistSort(ArtistSort value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.artistSort, value.name);
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(artistSort: value));
  }

  Future<void> setPlaylistSort(PlaylistSort value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.playlistSort, value.name);
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(playlistSort: value));
  }

  Future<void> setAlbumView(LibraryViewMode value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.albumView, value.name);
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(albumView: value));
  }

  Future<void> setArtistView(LibraryViewMode value) async {
    await _ensurePrefs();
    await _prefs!.setString(LibraryViewPrefsKeys.artistView, value.name);
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(artistView: value));
  }

  Future<void> setAlbumGenres(List<String> values) async {
    await _ensurePrefs();
    await _prefs!.setString(
        LibraryViewPrefsKeys.albumGenres, jsonEncode(values));
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
        .copyWith(albumGenres: List.unmodifiable(values)));
  }

  Future<void> setArtistGenres(List<String> values) async {
    await _ensurePrefs();
    await _prefs!.setString(
        LibraryViewPrefsKeys.artistGenres, jsonEncode(values));
    state = AsyncValue.data((state.asData?.value ?? LibraryViewPrefs.defaults)
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

/// Synchronous accessor used by the Library UI. Returns defaults until
/// the async future resolves; persistence still happens asynchronously
/// via the underlying notifier. Spec §7 risk 9: avoids the "first build
/// paints unsorted/unfiltered" flicker on cold start.
final libraryViewPrefsSyncProvider = Provider<LibraryViewPrefs>((ref) {
  return ref.watch(libraryViewPrefsProvider).asData?.value ??
      LibraryViewPrefs.defaults;
});
