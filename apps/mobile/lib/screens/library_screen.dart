import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/album_tile.dart';
import '../widgets/artist_tile.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'random_tab.dart';
import 'vibe_browse_screen.dart';

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

    return DefaultTabController(
      length: 6,
      child: AppShell(
        title: 'Library',
        currentTab: AppTab.tracks,
        child: Column(
          children: [
            const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Albums'),
                Tab(text: 'Artists'),
                Tab(text: 'Playlists'),
                Tab(text: 'Songs'),
                Tab(text: 'Random'),
                Tab(text: 'Vibe'),
              ],
            ),
            const Expanded(
              child: TabBarView(
                children: [
                  _AlbumsTab(),
                  _ArtistsTab(),
                  _PlaylistsTab(),
                  _SongsTab(),
                  RandomTab(),
                  VibeBrowseScreen(),
                ],
              ),
            ),
          ],
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
    return albumsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (albums) => albums.isEmpty
          ? const _EmptyTab(text: 'No albums yet.')
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
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
    return artistsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Library error: $e')),
      data: (artists) => artists.isEmpty
          ? const _EmptyTab(text: 'No artists yet.')
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
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
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.queue_music_outlined,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text('Coming in slice 6', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Vibe-driven and saved playlists ship alongside the on-device LLM.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
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

class _SongsTab extends ConsumerWidget {
  const _SongsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mergedAsync = ref.watch(trackWithPatchProvider);
    return mergedAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Scan failed: $e')),
      data: (merged) => merged.tracks.isEmpty
          ? const _EmptyTab(text: 'No tracks yet.')
          : _SongsList(tracks: merged.tracks),
    );
  }
}

/// Songs tab body — preserves slice 1's TracksScreen behaviour
/// byte-for-byte: tap plays from the row, long-press opens the
/// `Play Next` / `Add to Queue` modal sheet (slice 1 §11.8). The
/// only difference from slice 1 is the input list, which now flows
/// from [trackWithPatchProvider] so MB-sourced fields appear in the
/// title/subtitle without changing this widget.
class _SongsList extends ConsumerWidget {
  const _SongsList({required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        return ListTile(
          title: Text(
            _displayTitle(t),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitleOf(t) == null
              ? null
              : Text(_subtitleOf(t)!,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(_formatDuration(t.duration)),
          onTap: () => _playFrom(ref, i),
          onLongPress: () => _showTrackActions(context, ref, t),
        );
      },
    );
  }

  void _playFrom(WidgetRef ref, int index) {
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: index);
    // ignore: discarded_futures — fire-and-forget; errors surface via
    // the player state stream to NowPlayingScreen.
    ref.read(playbackServiceProvider).play();
  }

  void _showTrackActions(BuildContext context, WidgetRef ref, Track track) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _displayTitle(track),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: _subtitleOf(track) == null
                  ? null
                  : Text(_subtitleOf(track)!,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play Next'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref.read(queueProvider.notifier).playNext(track);
                _snack(context, 'Added to Up Next');
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to Queue'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref.read(queueProvider.notifier).addToUpcoming(track);
                _snack(context, 'Added to queue');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }
}

String _displayTitle(Track t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final path = t.path;
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

String? _subtitleOf(Track t) {
  final artist = t.artist ?? t.albumArtist;
  final album = t.album;
  if (artist == null && album == null) return null;
  if (artist == null) return album;
  if (album == null) return artist;
  return '$artist — $album';
}

String _formatDuration(Duration? d) {
  if (d == null) return '—';
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    final mm = m.toString().padLeft(2, '0');
    return '$h:$mm:$ss';
  }
  return '$m:$ss';
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}
