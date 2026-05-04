import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../providers/cast_providers.dart';
import '../providers/library_view_prefs.dart';
import '../providers/metadata_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/album_tile.dart';
import '../widgets/artist_tile.dart';
import '../widgets/library_filter_sheet.dart';
import '../widgets/responsive_columns.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

/// 3-tab Library surface — Albums / Artists / Playlists.
///
/// Slice-11 §C3 — the Songs tab promoted out of Library to the bottom
/// nav (see [AppShell.songsRoute]). Slice-11 §C1 retired the AI Compose
/// flow, so the Playlists tab renders a placeholder until a future
/// slice repurposes the `playlists` cache.db table for saved radio
/// sessions or library favourites.
///
/// Per-tab affordances:
/// - Albums: 2-col grid (default) or 1-col list — toggled by the
///   header's view button. Sort + genre filter via the filter sheet.
/// - Artists: 3-col avatar grid (default) or 1-col list. Same
///   filter-sheet sort + genre filter.
/// - Playlists: placeholder card; pure no-op until a future slice
///   re-enables a write surface.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  int _activeTabIndex = 0;

  LibrarySheetTab get _currentSheetTab {
    switch (_activeTabIndex) {
      case 0:
        return LibrarySheetTab.albums;
      case 1:
        return LibrarySheetTab.artists;
      case 2:
        return LibrarySheetTab.playlists;
      default:
        return LibrarySheetTab.albums;
    }
  }

  void _onTabChange() {
    // Use maybeOf so this is safe if called after the DefaultTabController
    // has been removed from the tree (e.g. during widget test teardown).
    final controller = DefaultTabController.maybeOf(context);
    if (controller == null) return;
    if (controller.indexIsChanging) {
      // Spec §7 risk 11 — dismiss any open sheet when the tab changes.
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    if (mounted) {
      setState(() {
        _activeTabIndex = controller.index;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Kick off the backfill queue when the user opens Library. Watching
    // it here (rather than in `PrismApp`) keeps the root widget
    // testable without platform-channel mocks for `path_provider` —
    // tests that don't render Library don't need the metadata repo.
    // ignore: unused_result
    ref.watch(backfillKickoffProvider);
    // Slice 9 — probe persisted manual IPs once on launch so the
    // STR-DN1080 (or any other receiver added on a multicast-blocked
    // network) re-appears in the cast sheet without requiring the
    // user to re-type its IP. The provider returns a `Future<void>`
    // and runs at most once per ProviderContainer lifetime.
    // ignore: unused_result
    ref.watch(castProbeManualOnLaunchProvider);

    final prefs = ref.watch(libraryViewPrefsSyncProvider);
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final tab = _currentSheetTab;

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          controller.removeListener(_onTabChange);
          controller.addListener(_onTabChange);
          return AppShell(
            title: 'Library',
            currentTab: AppTab.library,
            // Slice 7 §13 — wraps Library in the `library` Aurora variant
            // (least-accented). The Scaffold's AppBar stays Material-default;
            // only the body gains the backdrop.
            useAurora: AuroraVariant.library,
            showAppBar: false,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // Display title — wireframe drops the Material AppBar
                  // entirely and uses an inline 32 px serif-feel header.
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.s4,
                      tokens.s4,
                      tokens.s4,
                      tokens.s2,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Library',
                            style: scale.display36.copyWith(
                              fontSize: 32,
                              fontWeight: FontWeight.w500,
                              letterSpacing: -0.8,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        _ViewToggleButton(prefs: prefs, tab: tab),
                        SizedBox(width: tokens.s2),
                        _FilterButton(tab: tab),
                      ],
                    ),
                  ),
                  // Slice-11 §C3 — Library narrows to three tabs;
                  // Songs lifted out to a primary bottom-nav slot.
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: tokens.s4),
                    child: const TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: 'Albums'),
                        Tab(text: 'Artists'),
                        Tab(text: 'Playlists'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _AlbumsTab(prefs: prefs),
                        _ArtistsTab(prefs: prefs),
                        const _PlaylistsTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab({required this.prefs});
  final LibraryViewPrefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (rawAlbums) {
        final albums = sortAlbums(
          filterAlbumsByGenre(rawAlbums, prefs.albumGenres),
          prefs.albumSort,
        );
        if (albums.isEmpty) return const _EmptyTab(text: 'No albums yet.');
        if (prefs.albumView == LibraryViewMode.list) {
          return ListView.builder(
            padding: EdgeInsets.all(tokens.s4),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
              return ListTile(
                title: Text(a.title),
                subtitle: Text(a.artist),
                onTap: () => Navigator.of(context).push(
                  AlbumDetailScreen.route(a.id),
                ),
              );
            },
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final cols = columnsForWidth(
              constraints.maxWidth,
              targetTileWidth: 180,
              min: 2,
              max: 6,
            );
            return GridView.builder(
              padding: EdgeInsets.all(tokens.s4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: tokens.s4,
                crossAxisSpacing: tokens.s4,
                childAspectRatio: 0.8,
              ),
              itemCount: albums.length,
              itemBuilder: (context, i) {
                final a = albums[i];
                return AlbumTile(
                  album: a,
                  onTap: () => Navigator.of(context).push(
                    AlbumDetailScreen.route(a.id),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab({required this.prefs});
  final LibraryViewPrefs prefs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (rawArtists) {
        final artists = sortArtists(
          filterArtistsByGenre(rawArtists, prefs.artistGenres),
          prefs.artistSort,
        );
        if (artists.isEmpty) return const _EmptyTab(text: 'No artists yet.');
        if (prefs.artistView == LibraryViewMode.list) {
          return ListView.builder(
            padding: EdgeInsets.all(tokens.s4),
            itemCount: artists.length,
            itemBuilder: (context, i) {
              final a = artists[i];
              return ListTile(
                title: Text(a.name),
                subtitle: Text('${a.albumCount} albums'),
                onTap: () => Navigator.of(context).push(
                  ArtistDetailScreen.route(a.id),
                ),
              );
            },
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final cols = columnsForWidth(
              constraints.maxWidth,
              targetTileWidth: 110,
              min: 3,
              max: 8,
            );
            return GridView.builder(
              padding: EdgeInsets.all(tokens.s4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: tokens.s4,
                crossAxisSpacing: tokens.s4,
                childAspectRatio: 0.78,
              ),
              itemCount: artists.length,
              itemBuilder: (context, i) {
                final a = artists[i];
                return ArtistTile(
                  artist: a,
                  onTap: () => Navigator.of(context).push(
                    ArtistDetailScreen.route(a.id),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Slice-11 §C1 placeholder — the AI Compose flow that wrote into the
/// `playlists` cache.db v2 table is retired. The table itself stays
/// defined (additive migrations don't revert) but is unwritten until a
/// future slice repurposes it. The `playlistsProvider` and the slice-6
/// `_PlaylistRow` were removed in the same pass.
class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.s6),
        child: Glass(
          intensity: GlassIntensity.light,
          radius: tokens.s4,
          padding: EdgeInsets.all(tokens.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.queue_music_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              SizedBox(height: tokens.s4),
              Text(
                'Library playlists coming back in a future slice.',
                style: scale.body16,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}

class _ViewToggleButton extends ConsumerWidget {
  const _ViewToggleButton({required this.prefs, required this.tab});
  final LibraryViewPrefs prefs;
  final LibrarySheetTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAlbum = tab == LibrarySheetTab.albums;
    final isArtist = tab == LibrarySheetTab.artists;
    final disabled = !(isAlbum || isArtist);
    final mode = isAlbum ? prefs.albumView : prefs.artistView;
    final iconNext = mode == LibraryViewMode.grid
        ? Icons.view_list_outlined
        : Icons.grid_view_outlined;
    return Opacity(
      opacity: disabled ? 0.5 : 1.0,
      child: IconButton(
        tooltip: disabled ? 'Grid/list view (n/a)' : 'Grid/list view',
        icon: Icon(iconNext),
        onPressed: disabled
            ? null
            : () {
                final next = mode == LibraryViewMode.grid
                    ? LibraryViewMode.list
                    : LibraryViewMode.grid;
                if (isAlbum) {
                  // ignore: discarded_futures
                  ref
                      .read(libraryViewPrefsProvider.notifier)
                      .setAlbumView(next);
                } else if (isArtist) {
                  // ignore: discarded_futures
                  ref
                      .read(libraryViewPrefsProvider.notifier)
                      .setArtistView(next);
                }
              },
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.tab});
  final LibrarySheetTab tab;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Filter',
      icon: const Icon(Icons.tune),
      onPressed: () => LibraryFilterSheet.show(context, tab),
    );
  }
}
