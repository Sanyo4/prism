import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/album_tile.dart';
import '../widgets/artist_tile.dart';
import '../widgets/discover_grids.dart';
import '../widgets/embedded_art.dart';
import '../widgets/mood_chip_row.dart';
import 'ai_tab.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

/// Home — greeting + AI compose card + featured / artists / recent
/// rows. Mirrors `wireframe/music/screens/mobile-browse.jsx`'s
/// `HomeScreen`; the slices' Mood chip row is preserved at the top
/// so the user can still pivot the home queue by mood.
///
/// The layout deliberately *does not* use a Material [AppBar]. The
/// page header (`TUESDAY EVENING / Soft landing, welcome back.`) is
/// drawn as inline typography on the aurora to match the wireframe's
/// "made of light and glass" vocabulary.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
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
            tokens.s8 * 2,
          ),
          children: [
            // Greeting block — small caption + display title with
            // italic emphasis on the second line, matching the
            // wireframe's `Soft landing, welcome back.`
            const _GreetingBlock(),
            SizedBox(height: tokens.s4),
            // Hero one-tap AI playlist composer card.
            const _ComposeCard(),
            SizedBox(height: tokens.s4),
            // Mood chips — pre-existing slice-4 surface, polished
            // for the wireframe by riding the same horizontal
            // rhythm as the rest of the page.
            Text('Mood', style: scale.display20),
            SizedBox(height: tokens.s2),
            const MoodChipRow(),
            SizedBox(height: tokens.s4),
            // Featured row (horizontally scrolling album cards).
            const _FeaturedRow(),
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

class _ComposeCard extends StatelessWidget {
  const _ComposeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Navigator.of(context).pushNamed(AiTabScreen.routeName);
        },
        child: Glass(
          intensity: GlassIntensity.heavy,
          radius: 20,
          padding: EdgeInsets.all(tokens.s4),
          child: Stack(
            children: [
              // Lilac glow blob in the top-right corner.
              Positioned(
                right: -30,
                top: -30,
                child: IgnorePointer(
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          const Color(0xFFC8B4FF).withValues(alpha: 0.7),
                          const Color(0x00C8B4FF),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              Color(0xFF9BB8FF),
                              Color(0xFFD0A8FF),
                            ],
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Color(0x809BB8FF),
                              blurRadius: 8,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: tokens.s2),
                      Text(
                        'ONE-TAP PLAYLIST',
                        style: scale.caption13.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          color: const Color(0xFF6E4AB8),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.s2),
                  Text(
                    "Describe a mood.\nWe'll compose the rest.",
                    style: scale.display28.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.4,
                      height: 1.15,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: tokens.s1),
                  Text(
                    '"Rainy Sunday, slow coffee, jazz" →',
                    style: scale.body16.copyWith(
                      fontSize: 13,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeaturedRow extends ConsumerWidget {
  const _FeaturedRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final albumsAsync = ref.watch(albumsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHead(title: 'Featured', style: scale.display20),
        SizedBox(height: tokens.s2),
        SizedBox(
          height: 200,
          child: albumsAsync.when(
            loading: () => const _RowLoading(),
            error: (e, _) => _RowError(message: '$e'),
            data: (albums) {
              if (albums.isEmpty) {
                return const _RowEmpty(message: 'No albums yet.');
              }
              final featured = albums.take(8).toList();
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: featured.length,
                separatorBuilder: (_, _) => SizedBox(width: tokens.s3),
                itemBuilder: (_, i) => SizedBox(
                  width: 160,
                  child: AlbumTile(
                    album: featured[i],
                    onTap: () => Navigator.of(context).push(
                      AlbumDetailScreen.route(featured[i].id),
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
