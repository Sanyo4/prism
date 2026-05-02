import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browse/album_view.dart';
import '../browse/artist_view.dart';
import '../providers/metadata_providers.dart';
import '../widgets/album_tile.dart';
import '../widgets/artist_tile.dart';
import '../widgets/refresh_icon_button.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

/// Two-section random surface: 6 albums in a 2×3 grid + 6 artists in a
/// horizontal row. Independent seeds so per-section refresh changes
/// only that section. Seed lives in widget state — leaving the tab
/// re-shuffles by design.
class RandomTab extends ConsumerStatefulWidget {
  const RandomTab({super.key});

  @override
  ConsumerState<RandomTab> createState() => _RandomTabState();
}

class _RandomTabState extends ConsumerState<RandomTab> {
  int _albumSeed = DateTime.now().microsecondsSinceEpoch;
  // Mix-in a fixed hex constant so the two seeds aren't trivially
  // correlated when the clock has low entropy on emulators.
  int _artistSeed = DateTime.now().microsecondsSinceEpoch ^ 0x9E3779B1;

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(albumsProvider);
    final artistsAsync = ref.watch(artistsProvider);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _SectionHeader(
          title: 'Pick an Album',
          onRefresh: () => setState(() {
            _albumSeed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: albumsAsync.when(
            loading: () => const _LoadingTile(),
            error: (e, _) => _ErrorTile(message: 'Library unavailable'),
            data: (albums) => albums.isEmpty
                ? const _EmptyTile(label: 'No albums yet.')
                : _AlbumGrid(albums: _pickAlbums(albums)),
          ),
        ),
        const SizedBox(height: 24),
        _SectionHeader(
          title: 'Pick an Artist',
          onRefresh: () => setState(() {
            _artistSeed ^= DateTime.now().microsecondsSinceEpoch;
          }),
        ),
        SizedBox(
          height: 140,
          child: artistsAsync.when(
            loading: () => const _LoadingTile(),
            error: (e, _) => _ErrorTile(message: 'Library unavailable'),
            data: (artists) => artists.isEmpty
                ? const _EmptyTile(label: 'No artists yet.')
                : _ArtistRow(artists: _pickArtists(artists)),
          ),
        ),
      ],
    );
  }

  List<AlbumView> _pickAlbums(List<AlbumView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_albumSeed))).take(6).toList();
  }

  List<ArtistView> _pickArtists(List<ArtistView> all) {
    if (all.isEmpty) return const [];
    return (List.of(all)..shuffle(Random(_artistSeed))).take(6).toList();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onRefresh});
  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          RefreshIconButton(onPressed: onRefresh),
        ],
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.albums});
  final List<AlbumView> albums;

  @override
  Widget build(BuildContext context) {
    // 2×3 grid: 3 columns, 2 rows. We don't use GridView here because
    // it forces a fixed extent; six manually-laid tiles let the tile
    // widget pick its own intrinsic size and avoid layout assertions
    // when the artist surface re-renders.
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
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

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.artists});
  final List<ArtistView> artists;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: artists.length,
      separatorBuilder: (context, index) => const SizedBox(width: 12),
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
  }
}

class _LoadingTile extends StatelessWidget {
  const _LoadingTile();
  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
}

class _EmptyTile extends StatelessWidget {
  const _EmptyTile({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Center(child: Text(label));
}
