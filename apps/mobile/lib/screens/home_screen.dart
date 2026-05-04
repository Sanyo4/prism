import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../providers/library_providers.dart';
import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/artist_tile.dart';
import '../widgets/discover_grids.dart';
import '../widgets/embedded_art.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

/// Home — greeting + recents + discover grids. Slice-11 §C2 strips the
/// AI Compose hero card and the mood-chip row; mood selection now lives
/// on the Songs tab as multi-select chips, and "make me a vibe" is
/// expressed by long-press → Start Radio rather than a chatbot prompt.
///
/// Layout, top → bottom:
///   1. Greeting block ("TUESDAY EVENING / Soft landing, welcome back.")
///   2. Discover albums grid
///   3. Discover artists grid
///   4. Artists strip
///   5. Recently played grid
///   6. Recently added grid (slice-11 §C2)
///
/// The layout deliberately *does not* use a Material [AppBar]. The
/// page header is drawn as inline typography on the aurora to match
/// the wireframe's "made of light and glass" vocabulary.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    return AppShell(
      title: 'Home',
      currentTab: AppTab.home,
      useAurora: AuroraVariant.home,
      showAppBar: false,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            tokens.s4,
            tokens.s2,
            tokens.s4,
            // Leave room for the floating MiniPlayer + BottomNav.
            tokens.s8,
          ),
          children: [
            // Greeting block — small caption + display title with
            // italic emphasis on the second line, matching the
            // wireframe's `Soft landing, welcome back.`
            const _GreetingBlock(),
            SizedBox(height: tokens.s4),
            // Discover albums grid (2×3 with independent refresh).
            const DiscoverAlbumsGrid(),
            SizedBox(height: tokens.s4),
            // Discover artists grid (2×3 with independent refresh).
            const DiscoverArtistsGrid(),
            SizedBox(height: tokens.s4),
            // Artists strip (horizontally scrolling avatars).
            const _ArtistsRow(),
            SizedBox(height: tokens.s4),
            // 2x3 recently-played grid of glass list rows.
            const _RecentlyPlayedGrid(),
            SizedBox(height: tokens.s4),
            // Slice-11 §C2 — recently added grid (top 6 albums by mtime
            // descending). Uses the same tile shape as Discover albums
            // for visual rhyme.
            const _RecentlyAddedGrid(),
          ],
        ),
      ),
    );
  }
}

class _GreetingBlock extends StatelessWidget {
  const _GreetingBlock();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final caption = _captionForNow();
    return Padding(
      padding: EdgeInsets.only(top: tokens.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caption,
            style: scale.caption13.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          SizedBox(height: tokens.s1),
          // Display title — first line bold, second line italic at
          // 60% alpha. Wireframe puts both in the same scale.
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: 'Soft landing,\n',
                  style: scale.display36.copyWith(
                    fontSize: 30,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.8,
                    height: 1.05,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: 'welcome back.',
                  style: scale.display36.copyWith(
                    fontSize: 30,
                    fontWeight: FontWeight.w400,
                    fontStyle: FontStyle.italic,
                    letterSpacing: -0.8,
                    height: 1.05,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _captionForNow() {
    final now = DateTime.now();
    final weekday = const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][now.weekday - 1];
    final hour = now.hour;
    final daypart = hour < 5
        ? 'Late Night'
        : hour < 12
            ? 'Morning'
            : hour < 17
                ? 'Afternoon'
                : hour < 21
                    ? 'Evening'
                    : 'Tonight';
    return '$weekday $daypart'.toUpperCase();
  }
}

class _ArtistsRow extends ConsumerWidget {
  const _ArtistsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final artistsAsync = ref.watch(artistsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHead(title: 'Artists you love', style: scale.display20),
        SizedBox(height: tokens.s2),
        SizedBox(
          height: 130,
          child: artistsAsync.when(
            loading: () => const _RowLoading(),
            error: (e, _) => _RowError(message: '$e'),
            data: (artists) {
              if (artists.isEmpty) {
                return const _RowEmpty(message: 'No artists yet.');
              }
              final featured = artists.take(8).toList();
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: featured.length,
                separatorBuilder: (_, _) => SizedBox(width: tokens.s3),
                itemBuilder: (_, i) => SizedBox(
                  width: 92,
                  child: ArtistTile(
                    artist: featured[i],
                    onTap: () => Navigator.of(context).push(
                      ArtistDetailScreen.route(featured[i].id),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RecentlyPlayedGrid extends ConsumerWidget {
  const _RecentlyPlayedGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final mergedAsync = ref.watch(trackWithPatchProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHead(title: 'Recently played', style: scale.display20),
        SizedBox(height: tokens.s2),
        mergedAsync.when(
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => _RowError(message: '$e'),
          data: (merged) {
            final tracks = merged.tracks.take(6).toList();
            if (tracks.isEmpty) return const _RowEmpty(message: 'No tracks yet.');
            return GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: tokens.s2,
              mainAxisSpacing: tokens.s2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 3.4,
              children: [
                for (final t in tracks)
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        ref.read(queueProvider.notifier).loadContext(
                              [t],
                              startIndex: 0,
                            );
                        // ignore: discarded_futures
                        ref.read(playbackServiceProvider).play();
                      },
                      child: Glass(
                        intensity: GlassIntensity.light,
                        radius: 14,
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: Image(
                                  image: EmbeddedArtImage(t.path),
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  frameBuilder: (_, child, frame, _) {
                                    if (frame == null) {
                                      return ColoredBox(
                                        color: theme.colorScheme.surface,
                                        child: const Icon(
                                          Icons.music_note,
                                          size: 24,
                                          color: Colors.white70,
                                        ),
                                      );
                                    }
                                    return child;
                                  },
                                  errorBuilder: (_, _, _) => ColoredBox(
                                    color: theme.colorScheme.surface,
                                    child: const Icon(
                                      Icons.music_note,
                                      size: 24,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: tokens.s2),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    t.title ?? _basename(t.path),
                                    style: scale.caption13.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (t.artist != null)
                                    Text(
                                      t.artist!,
                                      style: scale.caption13.copyWith(
                                        fontSize: 10,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _basename(String p) {
    final i = p.lastIndexOf('/');
    final name = i < 0 ? p : p.substring(i + 1);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// Slice-11 §C2 — Recently added albums (top 6 by max(`Track.mtimeMs`)
/// descending). [Track] doesn't carry a clean `dateAdded` timestamp, so
/// we reuse the same `mtimeMs` proxy that `sortAlbums(...,
/// AlbumSort.recentlyAdded)` already uses for the Library tab. Tile
/// shape mirrors `_RecentlyPlayedGrid` (2-col compact glass row) so the
/// two recents grids visually rhyme.
// TODO(slice-12): expose a real `dateAdded` on Track sourced from
// either filesystem ctime or the cache row's first-seen timestamp.
class _RecentlyAddedGrid extends ConsumerWidget {
  const _RecentlyAddedGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final albumsAsync = ref.watch(recentlyAddedAlbumsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHead(title: 'Recently added', style: scale.display20),
        SizedBox(height: tokens.s2),
        albumsAsync.when(
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => _RowError(message: '$e'),
          data: (albums) {
            if (albums.isEmpty) return const _RowEmpty(message: 'No albums yet.');
            return GridView.count(
              crossAxisCount: 2,
              crossAxisSpacing: tokens.s2,
              mainAxisSpacing: tokens.s2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 3.4,
              children: [
                for (final a in albums) _RecentlyAddedTile(album: a),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _RecentlyAddedTile extends StatelessWidget {
  const _RecentlyAddedTile({required this.album});
  final AlbumView album;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    // Pick the first track's path so the embedded-art image source has
    // a real audio file to read tags from. AlbumView.coverUrl would
    // need a NetworkImage / cached_network_image hop; the embedded-art
    // fallback already covers most cases without the extra dependency.
    final firstPath =
        album.tracks.isNotEmpty ? album.tracks.first.path : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          AlbumDetailScreen.route(album.id),
        ),
        child: Glass(
          intensity: GlassIntensity.light,
          radius: 14,
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: firstPath == null
                      ? ColoredBox(
                          color: theme.colorScheme.surface,
                          child: const Icon(
                            Icons.album_outlined,
                            size: 24,
                            color: Colors.white70,
                          ),
                        )
                      : Image(
                          image: EmbeddedArtImage(firstPath),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          frameBuilder: (_, child, frame, _) {
                            if (frame == null) {
                              return ColoredBox(
                                color: theme.colorScheme.surface,
                                child: const Icon(
                                  Icons.album_outlined,
                                  size: 24,
                                  color: Colors.white70,
                                ),
                              );
                            }
                            return child;
                          },
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: theme.colorScheme.surface,
                            child: const Icon(
                              Icons.album_outlined,
                              size: 24,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                ),
              ),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      album.title,
                      style: scale.caption13.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      album.artist,
                      style: scale.caption13.copyWith(
                        fontSize: 10,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.title, required this.style});

  final String title;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: style),
        Text(
          'See all',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

class _RowLoading extends StatelessWidget {
  const _RowLoading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class _RowError extends StatelessWidget {
  const _RowError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('Couldn\'t load: $message'));
}

class _RowEmpty extends StatelessWidget {
  const _RowEmpty({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        message,
        style: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}
