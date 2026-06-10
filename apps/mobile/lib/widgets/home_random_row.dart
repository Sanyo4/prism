import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../providers/metadata_providers.dart';
import '../screens/album_detail_screen.dart';
import 'album_tile.dart';
import 'refresh_icon_button.dart';

/// "Can't decide?" row: 3 albums + a refresh button. Self-seeded so
/// scroll-back keeps the same trio until the user taps Refresh —
/// matches the slice 7 polish brief without the polished art.
class HomeRandomRow extends ConsumerStatefulWidget {
  const HomeRandomRow({super.key});

  @override
  ConsumerState<HomeRandomRow> createState() => _HomeRandomRowState();
}

class _HomeRandomRowState extends ConsumerState<HomeRandomRow> {
  // Per-instance seed. New instance (e.g. after rebuild on a hot
  // restart) re-seeds; tap-to-refresh bumps it. Kept as plain int so
  // we can `Random(seed)` deterministically.
  int _seed = DateTime.now().microsecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final albumsAsync = ref.watch(albumsProvider);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s2),
      child: Glass(
        intensity: GlassIntensity.light,
        radius: tokens.s4,
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s3, tokens.s3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  "Can't decide?",
                  style: scale.display20,
                ),
                const Spacer(),
                RefreshIconButton(
                  onPressed: () => setState(() {
                    _seed ^= DateTime.now().microsecondsSinceEpoch;
                  }),
                ),
              ],
            ),
            SizedBox(height: tokens.s1),
            albumsAsync.when(
              loading: () => const SizedBox(
                height: 156,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => SizedBox(
                height: 156,
                child: Center(
                  child: Text(
                    'Library unavailable',
                    style: scale.body16
                        .copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ),
              data: (albums) => albums.isEmpty
                  ? const SizedBox(
                      height: 156,
                      child: Center(child: Text('No albums yet')),
                    )
                  : _Picks(albums: _pick(albums)),
            ),
          ],
        ),
      ),
    );
  }

  /// Picks 3 albums by shuffling a copy with a seeded Random — pure
  /// client-side. Slice 4's SQLite cache does not change this code.
  List<AlbumView> _pick(List<AlbumView> all) {
    if (all.isEmpty) return const [];
    final copy = List.of(all)..shuffle(Random(_seed));
    return copy.take(3).toList(growable: false);
  }
}

class _Picks extends StatelessWidget {
  const _Picks({required this.albums});
  final List<AlbumView> albums;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: albums.length,
        separatorBuilder: (context, index) => SizedBox(width: tokens.s3),
        itemBuilder: (context, i) {
          final album = albums[i];
          return AlbumTile(
            album: album,
            onTap: () => Navigator.of(context).push(
              AlbumDetailScreen.route(album.id),
            ),
          );
        },
      ),
    );
  }
}
