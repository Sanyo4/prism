import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/embedded_art.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

/// Search — large display title, glass search field, and a 2-col
/// "Browse by mood" tile grid.
///
/// Mirrors `wireframe/music/screens/mobile-browse.jsx`'s `SearchScreen`.
/// The query filter is local-only for now (no backend / FTS yet); it
/// runs against the in-memory albums + artists + tracks the rest of
/// the UI is already drawing on, so the surface keeps working when
/// offline.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;

    return AppShell(
      title: 'Search',
      currentTab: AppTab.search,
      useAurora: AuroraVariant.library,
      showAppBar: false,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            tokens.s4,
            tokens.s4,
            tokens.s4,
            tokens.s8 * 2,
          ),
          children: [
            // Page title — wireframe's display 32 weight 500.
            Text(
              'Search',
              style: scale.display36.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
                color: theme.colorScheme.onSurface,
              ),
            ),
            SizedBox(height: tokens.s4),
            // Glass search input.
            Glass(
              intensity: GlassIntensity.light,
              radius: 16,
              padding: EdgeInsets.symmetric(
                horizontal: tokens.s3,
                vertical: tokens.s2,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 20,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                  SizedBox(width: tokens.s2),
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Artists, albums, songs, moods…',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45),
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (value) => setState(() => _query = value),
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: tokens.s4),
            if (_query.isEmpty) ...[
              Text(
                'Browse by mood',
                style: scale.display20.copyWith(fontSize: 14),
              ),
              SizedBox(height: tokens.s2),
              const _MoodGrid(),
            ] else ...[
              _SearchResults(query: _query),
            ],
          ],
        ),
      ),
    );
  }
}

class _MoodGrid extends StatelessWidget {
  const _MoodGrid();

  // Six lightweight gradient tiles — names match the slice-4 mood
  // chips so tapping into Search → Mood lands on a familiar surface.
  // Slice-11 §C1 retired `MoodResultsScreen`; tapping a tile now
  // switches to the Songs tab (the new mood-shuffle entry point).
  // Chip seeding into the Songs notifier is deferred to slice-12.
  static const _tiles = <_MoodTile>[
    _MoodTile('Happy', Color(0xFFFFD8A8)),
    _MoodTile('Chill', Color(0xFFB8D8FF)),
    _MoodTile('Focus', Color(0xFFD8C8FF)),
    _MoodTile('Energetic', Color(0xFFFFB8C8)),
    _MoodTile('Sad', Color(0xFFC8D8E8)),
    _MoodTile('Late Night', Color(0xFFB8B8E8)),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: tokens.s2,
      mainAxisSpacing: tokens.s2,
      childAspectRatio: 2.4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: _tiles
          .map((t) => _MoodCard(
                tile: t,
                onTap: () => Navigator.of(context)
                    .pushReplacementNamed(AppShell.songsRoute),
              ))
          .toList(),
    );
  }
}

class _MoodTile {
  const _MoodTile(this.label, this.color);
  final String label;
  final Color color;
}

class _MoodCard extends StatelessWidget {
  const _MoodCard({required this.tile, this.onTap});

  final _MoodTile tile;

  /// Tap handler. Set by [_MoodGrid] to switch to the Songs tab —
  /// slice-11 §C1 retired the old `MoodResultsScreen` push.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              tile.color,
              Colors.white.withValues(alpha: 0.4),
            ],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0x14000000),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.7),
            width: 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                // Glow blob in the bottom-right corner.
                Positioned(
                  right: -10,
                  bottom: -10,
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    tile.label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A2540),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final albumsAsync = ref.watch(albumsProvider);
    final artistsAsync = ref.watch(artistsProvider);
    final mergedAsync = ref.watch(trackWithPatchProvider);

    final lower = query.toLowerCase();

    final albumMatches = albumsAsync.maybeWhen(
      data: (xs) => xs
          .where((a) =>
              a.title.toLowerCase().contains(lower) ||
              a.artist.toLowerCase().contains(lower))
          .take(6)
          .toList(),
      orElse: () => <AlbumView>[],
    );
    final artistMatches = artistsAsync.maybeWhen(
      data: (xs) => xs
          .where((a) => a.name.toLowerCase().contains(lower))
          .take(6)
          .toList(),
      orElse: () => <ArtistView>[],
    );
    final trackMatches = mergedAsync.maybeWhen(
      data: (m) => m.tracks
          .where((t) =>
              (t.title?.toLowerCase().contains(lower) ?? false) ||
              (t.artist?.toLowerCase().contains(lower) ?? false))
          .take(8)
          .toList(),
      orElse: () => <Track>[],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (artistMatches.isNotEmpty) ...[
          Text('Artists', style: scale.display20.copyWith(fontSize: 14)),
          SizedBox(height: tokens.s2),
          for (final a in artistMatches)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(a.name),
              onTap: () => Navigator.of(context).push(
                ArtistDetailScreen.route(a.id),
              ),
            ),
          SizedBox(height: tokens.s4),
        ],
        if (albumMatches.isNotEmpty) ...[
          Text('Albums', style: scale.display20.copyWith(fontSize: 14)),
          SizedBox(height: tokens.s2),
          for (final a in albumMatches)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.album_outlined),
              title: Text(a.title),
              subtitle: Text(a.artist),
              onTap: () => Navigator.of(context).push(
                AlbumDetailScreen.route(a.id),
              ),
            ),
          SizedBox(height: tokens.s4),
        ],
        if (trackMatches.isNotEmpty) ...[
          Text('Songs', style: scale.display20.copyWith(fontSize: 14)),
          SizedBox(height: tokens.s2),
          for (final t in trackMatches)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Image(
                    image: EmbeddedArtImage(t.path),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => ColoredBox(
                      color: theme.colorScheme.surface,
                      child:
                          const Icon(Icons.music_note, color: Colors.white70),
                    ),
                    frameBuilder: (_, child, frame, _) {
                      if (frame == null) {
                        return ColoredBox(
                          color: theme.colorScheme.surface,
                          child: const Icon(Icons.music_note,
                              color: Colors.white70),
                        );
                      }
                      return child;
                    },
                  ),
                ),
              ),
              title: Text(t.title ?? t.path.split('/').last),
              subtitle: Text(t.artist ?? '—'),
              onTap: () {
                ref
                    .read(queueProvider.notifier)
                    .loadContext([t], startIndex: 0);
                // ignore: discarded_futures
                ref.read(playbackServiceProvider).play();
              },
            ),
        ],
        if (albumMatches.isEmpty &&
            artistMatches.isEmpty &&
            trackMatches.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.s8),
            child: Center(
              child: Text(
                'No matches.',
                style: TextStyle(
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
