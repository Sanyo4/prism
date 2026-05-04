import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/genre_options_provider.dart';
import '../providers/library_view_prefs.dart';

/// Tab identifier — drives the sheet's section selection.
enum LibrarySheetTab { albums, artists, playlists, songs }

/// Glass bottom-sheet hosting per-tab sort + filter controls. Spec §2.5
/// renders this with `Glass(intensity: heavy, radius: 24)`.
class LibraryFilterSheet extends ConsumerWidget {
  const LibraryFilterSheet({super.key, required this.tab});
  final LibrarySheetTab tab;

  static Future<void> show(BuildContext context, LibrarySheetTab tab) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => LibraryFilterSheet(tab: tab),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s4, tokens.s4),
        child: Glass(
          intensity: GlassIntensity.heavy,
          radius: 24,
          padding: EdgeInsets.all(tokens.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(_titleFor(tab), style: scale.display20),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _reset(ref, tab),
                    child: const Text('Reset'),
                  ),
                ],
              ),
              SizedBox(height: tokens.s2),
              ..._sortSection(ref, prefs, tokens, scale),
              if (tab == LibrarySheetTab.albums ||
                  tab == LibrarySheetTab.artists) ...[
                SizedBox(height: tokens.s4),
                _GenreSection(tab: tab),
              ],
              SizedBox(height: tokens.s4),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _titleFor(LibrarySheetTab tab) {
    switch (tab) {
      case LibrarySheetTab.albums:
        return 'Sort & filter albums';
      case LibrarySheetTab.artists:
        return 'Sort & filter artists';
      case LibrarySheetTab.playlists:
        return 'Sort playlists';
      case LibrarySheetTab.songs:
        return 'Songs';
    }
  }

  List<Widget> _sortSection(
    WidgetRef ref,
    LibraryViewPrefs prefs,
    SpaceTokens tokens,
    TypographyScale scale,
  ) {
    switch (tab) {
      case LibrarySheetTab.albums:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in AlbumSort.values)
            RadioListTile<AlbumSort>(
              value: v,
              groupValue: prefs.albumSort,
              title: Text(_albumSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setAlbumSort(value);
              },
            ),
        ];
      case LibrarySheetTab.artists:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in ArtistSort.values)
            RadioListTile<ArtistSort>(
              value: v,
              groupValue: prefs.artistSort,
              title: Text(_artistSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setArtistSort(value);
              },
            ),
        ];
      case LibrarySheetTab.playlists:
        return [
          Text('Sort', style: scale.caption13),
          for (final v in PlaylistSort.values)
            RadioListTile<PlaylistSort>(
              value: v,
              groupValue: prefs.playlistSort,
              title: Text(_playlistSortLabel(v)),
              onChanged: (value) {
                if (value == null) return;
                // ignore: discarded_futures
                ref.read(libraryViewPrefsProvider.notifier).setPlaylistSort(value);
              },
            ),
        ];
      case LibrarySheetTab.songs:
        return [
          Text(
            'Songs sort is driven by the chip row + tempo dropdown above.',
            style: scale.caption13,
          ),
        ];
    }
  }

  void _reset(WidgetRef ref, LibrarySheetTab tab) {
    final notifier = ref.read(libraryViewPrefsProvider.notifier);
    switch (tab) {
      case LibrarySheetTab.albums:
        // ignore: discarded_futures
        notifier.setAlbumSort(AlbumSort.title);
        // ignore: discarded_futures
        notifier.setAlbumGenres(const <String>[]);
      case LibrarySheetTab.artists:
        // ignore: discarded_futures
        notifier.setArtistSort(ArtistSort.name);
        // ignore: discarded_futures
        notifier.setArtistGenres(const <String>[]);
      case LibrarySheetTab.playlists:
        // ignore: discarded_futures
        notifier.setPlaylistSort(PlaylistSort.createdDesc);
      case LibrarySheetTab.songs:
        break;
    }
  }

  static String _albumSortLabel(AlbumSort v) {
    switch (v) {
      case AlbumSort.title:
        return 'Title';
      case AlbumSort.artist:
        return 'Artist';
      case AlbumSort.yearNewest:
        return 'Year (newest first)';
      case AlbumSort.yearOldest:
        return 'Year (oldest first)';
      case AlbumSort.recentlyAdded:
        return 'Recently added';
    }
  }

  static String _artistSortLabel(ArtistSort v) {
    switch (v) {
      case ArtistSort.name:
        return 'Name';
      case ArtistSort.albumCountDesc:
        return 'Album count (most first)';
      case ArtistSort.recentlyAdded:
        return 'Recently added';
    }
  }

  static String _playlistSortLabel(PlaylistSort v) {
    switch (v) {
      case PlaylistSort.createdDesc:
        return 'Created (newest first)';
      case PlaylistSort.name:
        return 'Name';
    }
  }
}

class _GenreSection extends ConsumerStatefulWidget {
  const _GenreSection({required this.tab});
  final LibrarySheetTab tab;
  @override
  ConsumerState<_GenreSection> createState() => _GenreSectionState();
}

class _GenreSectionState extends ConsumerState<_GenreSection> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final asyncOptions = ref.watch(genreOptionsProvider);
    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    final selectedKeys = widget.tab == LibrarySheetTab.albums
        ? prefs.albumGenres
        : prefs.artistGenres;
    return asyncOptions.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: EdgeInsets.all(tokens.s2),
        child: Text('Genre list unavailable: $e',
            style: TextStyle(color: theme.colorScheme.error)),
      ),
      data: (options) {
        final showSearch = options.length > 50;
        final filtered = _filter.isEmpty
            ? options
            : options
                .where((o) =>
                    o.label.toLowerCase().contains(_filter.toLowerCase()))
                .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Genres (OR)', style: scale.caption13),
            if (showSearch) ...[
              SizedBox(height: tokens.s2),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search genres',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ],
            SizedBox(height: tokens.s2),
            Wrap(
              spacing: tokens.s2,
              runSpacing: tokens.s1,
              children: [
                for (final option in filtered)
                  FilterChip(
                    label: Text(option.label),
                    selected: option.storageKeys
                        .any((k) => selectedKeys.contains(k)),
                    onSelected: (selected) {
                      final next = List<String>.from(selectedKeys);
                      if (selected) {
                        for (final k in option.storageKeys) {
                          if (!next.contains(k)) next.add(k);
                        }
                      } else {
                        next.removeWhere(option.storageKeys.contains);
                      }
                      if (widget.tab == LibrarySheetTab.albums) {
                        // ignore: discarded_futures
                        ref
                            .read(libraryViewPrefsProvider.notifier)
                            .setAlbumGenres(next);
                      } else {
                        // ignore: discarded_futures
                        ref
                            .read(libraryViewPrefsProvider.notifier)
                            .setArtistGenres(next);
                      }
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
