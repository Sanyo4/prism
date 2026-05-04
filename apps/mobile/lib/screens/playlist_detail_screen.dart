import 'dart:math' show Random;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:prism_ui/ui.dart';

import '../providers/cache_db_providers.dart';
import '../providers/library_providers.dart' show tracksProvider;
import '../providers/playback_providers.dart';
import '../providers/playlists_provider.dart';
import '../providers/radio_providers.dart';
import 'radio_context_sheet.dart';

/// Hero detail screen for a persisted AI-Compose playlist.
///
/// Cover region: a deterministic gradient seeded by the playlist title (no
/// album art — these are synthetic playlists). Metadata Glass card with
/// Play / Shuffle / Delete actions on the right. Track list with the same
/// onTap (load + play) and onLongPress (RadioContextSheet TrackSeed) as
/// AlbumDetailScreen. Tracks whose path is not in the live library are
/// silently skipped (files may go missing without invalidating the record).
class PlaylistDetailScreen extends ConsumerWidget {
  const PlaylistDetailScreen({super.key, required this.playlistId});
  final int playlistId;

  static Route<void> route(int id) =>
      MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlistId: id));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<PlaylistRecord?>(
      future: () async {
        final db = await ref.read(cacheDbProvider.future);
        return db.playlists.getById(playlistId);
      }(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final playlist = snap.data;
        if (playlist == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Playlist not found')),
          );
        }
        return _PlaylistDetailBody(playlist: playlist);
      },
    );
  }
}

class _PlaylistDetailBody extends ConsumerWidget {
  const _PlaylistDetailBody({required this.playlist});
  final PlaylistRecord playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final tracksAsync = ref.watch(tracksProvider);

    return tracksAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (allTracks) {
        // Map playlist track paths → live Tracks (skip missing).
        final byPath = {for (final t in allTracks) t.path: t};
        final tracks = <Track>[
          for (final p in playlist.trackPaths)
            if (byPath[p] != null) byPath[p]!,
        ];

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: AuroraBackground(
            variant: AuroraVariant.library,
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 280,
                  pinned: true,
                  flexibleSpace: FlexibleSpaceBar(
                    centerTitle: false,
                    titlePadding: EdgeInsets.fromLTRB(
                      tokens.s4,
                      0,
                      tokens.s4,
                      tokens.s3,
                    ),
                    title: Text(
                      playlist.title,
                      style: scale.display28.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Gradient backdrop from title hash.
                        _GradientBackdrop(seed: playlist.title),
                        // Sparkle overlay icon.
                        const Center(
                          child: Icon(
                            Icons.auto_awesome,
                            size: 96,
                            color: Color(0xCCFFFFFF),
                          ),
                        ),
                        // Bottom scrim for title legibility.
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 100,
                          child: ClipRect(
                            child: BackdropFilter(
                              filter:
                                  ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x00000000),
                                      Color(0x66000000),
                                    ],
                                  ),
                                ),
                                child: SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.s4,
                      tokens.s3,
                      tokens.s4,
                      tokens.s3,
                    ),
                    child: Glass(
                      intensity: GlassIntensity.medium,
                      radius: tokens.s4,
                      padding: EdgeInsets.all(tokens.s4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (playlist.blurb != null &&
                                    playlist.blurb!.isNotEmpty)
                                  Text(
                                    playlist.blurb!,
                                    style: scale.body16.copyWith(
                                      fontWeight: FontWeight.w500,
                                      fontStyle: FontStyle.italic,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (playlist.blurb != null &&
                                    playlist.blurb!.isNotEmpty)
                                  SizedBox(height: tokens.s1),
                                Text(
                                  '${tracks.length} of ${playlist.trackCount} tracks',
                                  style: scale.caption13.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: tokens.s3),
                          _PlaylistActions(
                            playlist: playlist,
                            tracks: tracks,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final track = tracks[i];
                      return ListTile(
                        leading: SizedBox(
                          width: 32,
                          child: Text(
                            '${i + 1}',
                            textAlign: TextAlign.right,
                            style: scale.caption13.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        title: Text(
                          track.title ?? _basename(track.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [track.artist, track.album]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' — '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          ref.read(queueProvider.notifier).loadContext(
                                tracks,
                                startIndex: i,
                              );
                          // ignore: discarded_futures
                          ref.read(playbackServiceProvider).play();
                        },
                        onLongPress: () async {
                          final pathToId =
                              await ref.read(pathToIdProvider.future);
                          final id = pathToId[track.path];
                          if (id == null) return;
                          if (!context.mounted) return;
                          RadioContextSheet.show(
                            context,
                            TrackSeed(
                              trackId: id,
                              title: track.title ?? _basename(track.path),
                            ),
                          );
                        },
                      );
                    },
                    childCount: tracks.length,
                  ),
                ),
                SliverPadding(
                    padding: EdgeInsets.only(bottom: tokens.s8)),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    final base = i < 0 ? path : path.substring(i + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

class _PlaylistActions extends ConsumerWidget {
  const _PlaylistActions({required this.playlist, required this.tracks});
  final PlaylistRecord playlist;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          tooltip: 'Play',
          icon: const Icon(Icons.play_arrow),
          onPressed: tracks.isEmpty
              ? null
              : () {
                  ref
                      .read(queueProvider.notifier)
                      .loadContext(tracks, startIndex: 0);
                  // ignore: discarded_futures
                  ref.read(playbackServiceProvider).play();
                },
        ),
        SizedBox(height: tokens.s1),
        IconButton(
          tooltip: 'Shuffle',
          icon: const Icon(Icons.shuffle),
          onPressed: tracks.isEmpty
              ? null
              : () {
                  final shuffled = List<Track>.of(tracks)..shuffle(Random());
                  ref
                      .read(queueProvider.notifier)
                      .loadContext(shuffled, startIndex: 0);
                  // ignore: discarded_futures
                  ref.read(playbackServiceProvider).play();
                },
        ),
        SizedBox(height: tokens.s1),
        IconButton(
          tooltip: 'Delete',
          icon: Icon(
            Icons.delete_outline,
            color: theme.colorScheme.error,
          ),
          onPressed: () async {
            final db = await ref.read(cacheDbProvider.future);
            await db.playlists.deleteById(playlist.id);
            ref.invalidate(playlistsProvider);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

/// Renders a deterministic two-stop linear gradient whose hue pair is
/// derived from the FNV-1a hash of [seed]. Used as the cover backdrop
/// for AI-Compose playlists (which have no album art).
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop({required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) {
    var h = 2166136261;
    for (final c in seed.codeUnits) {
      h = (h ^ c) * 16777619;
      h &= 0xFFFFFFFF;
    }
    final hueA = (h % 360).toDouble();
    final hueB = ((h ~/ 360) % 360).toDouble();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_pastel(hueA, sat: 0.6), _pastel(hueB, sat: 0.7)],
        ),
      ),
    );
  }

  Color _pastel(double hue, {double sat = 0.6}) {
    const l = 0.55;
    final c = (1 - (2 * l - 1).abs()) * sat;
    final hp = hue / 60.0;
    final x = c * (1 - ((hp % 2) - 1).abs());
    double r, g, b;
    if (hp < 1) {
      r = c;
      g = x;
      b = 0;
    } else if (hp < 2) {
      r = x;
      g = c;
      b = 0;
    } else if (hp < 3) {
      r = 0;
      g = c;
      b = x;
    } else if (hp < 4) {
      r = 0;
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      g = 0;
      b = c;
    } else {
      r = c;
      g = 0;
      b = x;
    }
    final m = l - c / 2;
    return Color.fromARGB(
      255,
      ((r + m) * 255).round().clamp(0, 255),
      ((g + m) * 255).round().clamp(0, 255),
      ((b + m) * 255).round().clamp(0, 255),
    );
  }
}
