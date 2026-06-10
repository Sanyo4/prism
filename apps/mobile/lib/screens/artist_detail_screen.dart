import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:prism_ui/ui.dart';

import '../browse/artist_view.dart';
import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../providers/radio_providers.dart';
import '../widgets/album_tile.dart';
import 'album_detail_screen.dart';
import 'radio_context_sheet.dart';

/// Avatar + Last.fm blurb (when key present) + tags + albums + top
/// tracks. The blurb is hidden silently when no MBID resolved or no
/// Last.fm key configured.
class ArtistDetailScreen extends ConsumerWidget {
  const ArtistDetailScreen({super.key, required this.artistId});

  final String artistId;

  static Route<void> route(String id) =>
      MaterialPageRoute(builder: (_) => ArtistDetailScreen(artistId: id));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistsAsync = ref.watch(artistsProvider);
    return artistsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Library error: $e')),
      ),
      data: (artists) {
        final artist = artists.where((a) => a.id == artistId).firstOrNull;
        if (artist == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Artist not found')),
            body: const Center(child: Text('No matching artist.')),
          );
        }
        return _ArtistDetailBody(artist: artist);
      },
    );
  }
}

class _ArtistDetailBody extends ConsumerWidget {
  const _ArtistDetailBody({required this.artist});
  final ArtistView artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return AuroraBackground(
      variant: AuroraVariant.library,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(artist.name)),
        body: ListView(
          padding: EdgeInsets.all(tokens.s4),
          children: [
          // Slice-10b: radio is track-only — the avatar no longer
          // long-presses into an artist-seed radio start. The
          // GestureDetector wrapper would have been pointless without
          // its handler so we drop it entirely; the bare avatar
          // renders the same.
          Center(
            child: CircleAvatar(
              radius: 56,
              child: Text(
                _initials(artist.name),
                style: scale.display20,
              ),
            ),
          ),
          SizedBox(height: tokens.s3),
          Center(
            child: Text(
              '${artist.albumCount} albums · ${artist.trackCount} tracks',
              style: scale.caption13.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(height: tokens.s6),
          if (artist.mbid != null)
            _LastfmBio(mbid: artist.mbid!),
          if (artist.mbid == null) const _NoMbidNudge(),
          SizedBox(height: tokens.s4),
          Text('Albums', style: scale.display20),
          SizedBox(height: tokens.s2),
          SizedBox(
            height: 220,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: artist.albums.length,
              separatorBuilder: (context, index) => SizedBox(width: tokens.s3),
              itemBuilder: (context, i) {
                final a = artist.albums[i];
                return AlbumTile(
                  album: a,
                  onTap: () => Navigator.of(context).push(
                    AlbumDetailScreen.route(a.id),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: tokens.s6),
          Text('Top tracks', style: scale.display20),
          for (final t in artist.topTracks)
            ListTile(
              dense: true,
              title: Text(t.title ?? _basename(t.path)),
              subtitle: t.album == null ? null : Text(t.album!),
              onTap: () => _playOne(ref, t),
              onLongPress: () => _openRadioSheetForTrack(context, ref, t),
            ),
          ],
        ),
      ),
    );
  }

  void _playOne(WidgetRef ref, Track t) {
    ref.read(queueProvider.notifier).loadContext([t], startIndex: 0);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  /// Slice-10b: long-press a track row → open the radio context sheet
  /// seeded from this track. Resolves the cache-db row id via
  /// [pathToIdProvider]; bails silently if the file hasn't been
  /// ingested yet (mirrors the existing track-row pattern in
  /// [album_detail_screen.dart] / [playlist_detail_screen.dart]).
  Future<void> _openRadioSheetForTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final pathToId = await ref.read(pathToIdProvider.future);
    final id = pathToId[track.path];
    if (id == null) return;
    if (!context.mounted) return;
    await RadioContextSheet.show(
      context,
      TrackSeed(
        trackId: id,
        title: track.title ?? _basename(track.path),
      ),
    );
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

class _LastfmBio extends ConsumerWidget {
  const _LastfmBio({required this.mbid});
  final String mbid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infoAsync = ref.watch(artistInfoProvider(mbid));
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return infoAsync.when(
      loading: () => Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.s2),
        child: const LinearProgressIndicator(minHeight: 2),
      ),
      error: (err, stack) => const SizedBox.shrink(),
      data: (info) {
        if (info == null) return const _NoBlurbNudge();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.bio,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: scale.body16,
            ),
            SizedBox(height: tokens.s2),
            Wrap(
              spacing: 6,
              children: [
                for (final tag in info.tags) Chip(label: Text(tag)),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _NoBlurbNudge extends StatelessWidget {
  const _NoBlurbNudge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.s1),
      child: Text(
        'No biography available. Add a Last.fm API key in Settings to '
        'fetch artist details.',
        style: scale.caption13.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _NoMbidNudge extends StatelessWidget {
  const _NoMbidNudge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.s1),
      child: Text(
        'No MusicBrainz match yet. Run a fresh scan with online metadata '
        'enabled to fetch artist info.',
        style: scale.caption13.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

extension _Firstish<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
