import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../providers/metadata_providers.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';
import 'album_tile.dart';
import 'artist_tile.dart';
import 'refresh_icon_button.dart';

/// Slice 10 §2.1 — Discover albums grid lifted from the retired
/// `RandomTab`. 2x3 grid, independent reseed via the grid's own
/// refresh button. Mounted on Home between the Featured row and the
/// Artists row.
class DiscoverAlbumsGrid extends ConsumerStatefulWidget {
  const DiscoverAlbumsGrid({super.key});

  @override
  ConsumerState<DiscoverAlbumsGrid> createState() =>
      _DiscoverAlbumsGridState();
}

class _DiscoverAlbumsGridState extends ConsumerState<DiscoverAlbumsGrid> {
  int _seed = DateTime.now().microsecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final albumsAsync = ref.watch(albumsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Discover albums',
          onRefresh: () => setState(() {
            _seed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: albumsAsync.when(
            loading: () => const _Loading(),
            error: (e, _) => const _Error('Library unavailable'),
            data: (all) => all.isEmpty
                ? const _Empty('No albums yet.')
                : _AlbumTiles(albums: _pick(all)),
          ),
        ),
      ],
    );
  }

  List<AlbumView> _pick(List<AlbumView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_seed))).take(6).toList();
  }
}

/// Slice 10 §2.1 — Discover artists grid. Independent seed (mixed-in
/// hex constant so the two seeds aren't trivially correlated when the
/// clock has low entropy on emulators — same trick the retired
/// RandomTab used).
class DiscoverArtistsGrid extends ConsumerStatefulWidget {
  const DiscoverArtistsGrid({super.key});

  @override
  ConsumerState<DiscoverArtistsGrid> createState() =>
      _DiscoverArtistsGridState();
}

class _DiscoverArtistsGridState extends ConsumerState<DiscoverArtistsGrid> {
  int _seed = DateTime.now().microsecondsSinceEpoch ^ 0x9E3779B1;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final artistsAsync = ref.watch(artistsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Discover artists',
          onRefresh: () => setState(() {
            _seed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: artistsAsync.when(
            loading: () => const _Loading(),
            error: (e, _) => const _Error('Library unavailable'),
            data: (all) => all.isEmpty
                ? const _Empty('No artists yet.')
                : _ArtistTiles(artists: _pick(all)),
          ),
        ),
      ],
    );
  }

  List<ArtistView> _pick(List<ArtistView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_seed))).take(6).toList();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onRefresh});
  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s2, tokens.s2),
      child: Row(
        children: [
          Text(title, style: scale.display20),
          const Spacer(),
          RefreshIconButton(onPressed: onRefresh),
        ],
      ),
    );
  }
}

class _AlbumTiles extends StatelessWidget {
  const _AlbumTiles({required this.albums});
  final List<AlbumView> albums;
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: tokens.s3,
      crossAxisSpacing: tokens.s3,
      childAspectRatio: 0.75,
      children: [
        for (final a in albums)
          AlbumTile(
            album: a,
            onTap: () => Navigator.of(context).push(
              AlbumDetailScreen.route(a.id),
            ),
          ),
      ],
    );
  }
}

class _ArtistTiles extends StatelessWidget {
  const _ArtistTiles({required this.artists});
  final List<ArtistView> artists;
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: tokens.s3,
      crossAxisSpacing: tokens.s3,
      childAspectRatio: 0.78,
      children: [
        for (final a in artists)
          ArtistTile(
            artist: a,
            onTap: () => Navigator.of(context).push(
              ArtistDetailScreen.route(a.id),
            ),
          ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
}

class _Error extends StatelessWidget {
  const _Error(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(message,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(16), child: Center(child: Text(message)));
}
