import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/cast_providers.dart';
import '../providers/metadata_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/album_tile.dart';
import '../widgets/artist_tile.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'songs_shuffle_tab.dart';

/// 6-tab Library surface. Slice 4 adds **Vibe** as a sixth tab —
/// classifier-native chips + tempo band, backed by the sidecar cache.
///
/// Tabs (left → right):
/// - Albums: 2-col grid of [AlbumTile]
/// - Artists: 2-col grid of [ArtistTile]
/// - Playlists: empty-state card ("Coming in slice 6")
/// - Songs: slice 1's flat tracks list, extracted into `SongsTab`
/// - Random: [RandomTab]
/// - Vibe: [VibeBrowseScreen] (slice 4)
///
/// The slice-4 plan §8 step 13 originally said "section above
/// Albums/Artists/Genres", but slice 2 already shipped tabs; we
/// reconcile by appending a sixth tab rather than restructuring the
/// surface.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return DefaultTabController(
      length: 4,
      child: AppShell(
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
                  ],
                ),
              ),
              // Wireframe restricts Library to four tabs (Albums /
              // Artists / Playlists / Songs). Random + Vibe are now
              // surfaced from the Search → mood tiles + Home mood row.
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.s4),
                child: const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'Albums'),
                    Tab(text: 'Artists'),
                    Tab(text: 'Playlists'),
                    Tab(text: 'Songs'),
                  ],
                ),
              ),
              const Expanded(
                child: TabBarView(
                  children: [
                    _AlbumsTab(),
                    _ArtistsTab(),
                    _PlaylistsTab(),
                    _SongsTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (albums) => albums.isEmpty
          ? const _EmptyTab(text: 'No albums yet.')
          : GridView.builder(
              padding: EdgeInsets.all(tokens.s4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
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
            ),
    );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (artists) => artists.isEmpty
          ? const _EmptyTab(text: 'No artists yet.')
          : GridView.builder(
              padding: EdgeInsets.all(tokens.s4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
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
            ),
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final scale = Theme.of(context).extension<TypographyScale>()!;
    return Center(
      child: Card(
        margin: EdgeInsets.all(tokens.s6),
        child: Padding(
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
              Text('Coming in slice 6', style: scale.display20),
              SizedBox(height: tokens.s2),
              Text(
                'Vibe-driven and saved playlists ship alongside the on-device LLM.',
                textAlign: TextAlign.center,
                style: scale.body16.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SongsTab extends StatelessWidget {
  const _SongsTab();
  @override
  Widget build(BuildContext context) => const SongsShuffleTab();
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}
