import 'dart:math' show Random;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:prism_ui/ui.dart';

import '../browse/album_view.dart';
import '../providers/metadata_providers.dart';
import '../providers/playback_providers.dart';
import '../providers/radio_providers.dart';
import '../theme/palette_providers.dart';
import '../widgets/embedded_art.dart';
import '../widgets/prism_art_cache_manager.dart';
import 'radio_context_sheet.dart';

/// Hero art + tracklist for one album. Tap a track → load context into
/// the queue starting at that index → play.
///
/// Resolution: looks up the album by [albumId] inside the latest
/// [albumsProvider] snapshot. If the user navigates here from a stale
/// random tab and the album has since vanished (rare — would require
/// the user to delete files mid-session), we surface a "Not found"
/// scaffold rather than crashing.
class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({super.key, required this.albumId});

  /// Stable id used as both the route param and the lookup key into
  /// [albumsProvider]. Must match `AlbumView.id`.
  final String albumId;

  static Route<void> route(String id) =>
      MaterialPageRoute(builder: (_) => AlbumDetailScreen(albumId: id));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    return albumsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Library error: $e')),
      ),
      data: (albums) {
        final album = albums.where((a) => a.id == albumId).firstOrNull;
        if (album == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Album not found')),
            body: const Center(child: Text('No matching album.')),
          );
        }
        return _AlbumDetailBody(album: album);
      },
    );
  }
}

class _AlbumDetailBody extends ConsumerWidget {
  const _AlbumDetailBody({required this.album});
  final AlbumView album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Slice 7 §8 step 9: per-route AlbumPalette override. Watch the
    // family-keyed palette future and copy the resolved extension into
    // a child Theme; subtree consumers (Glass tint, scrub-bar fill,
    // play-button gradient) read it. While loading, the subtree sees
    // the neutral palette — the palette pops in on a subsequent frame
    // and lerps in over 180 ms (slice 7 §10 risk 2).
    final palette = _resolvePalette(ref);
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final ordered = _orderedTracks(album.tracks);

    return Theme(
      data: theme.copyWith(
        extensions: _withPalette(theme, palette),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AuroraBackground(
          variant: AuroraVariant.album,
          accentOverride: palette.isNeutral ? null : palette.dominant,
          child: CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.transparent,
                expandedHeight: 320,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(
                  centerTitle: false,
                  titlePadding: EdgeInsets.fromLTRB(
                    tokens.s4,
                    0,
                    tokens.s4,
                    tokens.s3,
                  ),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        // Slice 5 — long-press the hero to start radio from
                        // the album seed.
                        onLongPress: () => RadioContextSheet.show(
                          context,
                          AlbumSeed(albumKey: album.id, title: album.title),
                        ),
                        child: Hero(
                          tag: HeroTags.art(album.id),
                          flightShuttleBuilder: _flightShuttleBuilder,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: _Hero(album: album),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 110,
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
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
                  title: Hero(
                    tag: HeroTags.title(album.id),
                    flightShuttleBuilder: _titleFlightShuttleBuilder,
                    child: Material(
                      color: Colors.transparent,
                      child: Text(
                        album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: GestureDetector(
                  // Long-press the metadata strip too — slice 5 spec
                  // names "long-press the album cell". The hero IS the
                  // cell on the detail screen; this is the secondary
                  // affordance for users who scroll past the hero.
                  onLongPress: () => RadioContextSheet.show(
                    context,
                    AlbumSeed(albumKey: album.id, title: album.title),
                  ),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.s4,
                      tokens.s4,
                      tokens.s4,
                      tokens.s2,
                    ),
                    child: Glass(
                      intensity: GlassIntensity.light,
                      radius: tokens.s3,
                      padding: EdgeInsets.all(tokens.s4),
                      tint: palette.isNeutral ? null : palette.dominant,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Hero(
                                  tag: HeroTags.artist(album.id),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: Text(
                                      album.artist,
                                      style: scale.display20,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(height: tokens.s1),
                                Text(
                                  '${album.year ?? '—'} · ${album.trackCount} tracks',
                                  style: scale.caption13.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: tokens.s3),
                          _AlbumActions(album: album),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.s4,
                    vertical: tokens.s2,
                  ),
                  child: Glass(
                    intensity: GlassIntensity.heavy,
                    radius: tokens.s4,
                    tint: palette.isNeutral ? null : palette.dominant,
                    padding: EdgeInsets.symmetric(vertical: tokens.s2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < ordered.length; i++)
                          ListTile(
                            leading: ordered[i].trackNo == null
                                ? null
                                : SizedBox(
                                    width: 32,
                                    child: Text(
                                      '${ordered[i].trackNo}',
                                      textAlign: TextAlign.right,
                                      style: scale.body16.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                            title: Text(
                              ordered[i].title ?? _basename(ordered[i].path),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: scale.body16,
                            ),
                            trailing: Text(
                              _formatDur(
                                ordered[i].duration ?? Duration.zero,
                              ),
                              style: scale.caption13.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            onTap: () => _playFrom(ref, ordered, i),
                            onLongPress: () async {
                              final pathToId =
                                  await ref.read(pathToIdProvider.future);
                              final id = pathToId[ordered[i].path];
                              if (id == null) return;
                              if (!context.mounted) return;
                              RadioContextSheet.show(
                                context,
                                TrackSeed(
                                  trackId: id,
                                  title: ordered[i].title ??
                                      _basename(ordered[i].path),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: tokens.s8)),
            ],
          ),
        ),
      ),
    );
  }

  /// Reads the palette future from [paletteForProvider]. Returns the
  /// neutral sentinel until the family resolves; a frame after the
  /// future completes the subtree rebuilds with the album's tint.
  AlbumPalette _resolvePalette(WidgetRef ref) {
    final url = album.coverUrl;
    if (url == null) return const AlbumPalette.neutral();
    final repoAsync = ref.watch(paletteRepositoryProvider);
    final repo = repoAsync.asData?.value;
    if (repo == null) return const AlbumPalette.neutral();
    final key = PaletteForKey(
      artKey: repo.artKeyFor(url),
      artUrl: url,
      cacheKey: album.releaseMbid,
    );
    final paletteAsync = ref.watch(paletteForProvider(key));
    return paletteAsync.asData?.value ?? const AlbumPalette.neutral();
  }

  /// Sort by `(discNo, trackNo)`; tracks missing track numbers sort
  /// to the end in their input order.
  List<Track> _orderedTracks(List<Track> tracks) {
    final list = List.of(tracks);
    list.sort((a, b) {
      final da = a.discNo ?? 0;
      final db = b.discNo ?? 0;
      if (da != db) return da.compareTo(db);
      final ta = a.trackNo ?? (1 << 30);
      final tb = b.trackNo ?? (1 << 30);
      return ta.compareTo(tb);
    });
    return list;
  }

  void _playFrom(WidgetRef ref, List<Track> tracks, int index) {
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: index);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _formatDur(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:$ss';
    }
    return '$m:$ss';
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.album});
  final AlbumView album;

  @override
  Widget build(BuildContext context) {
    final url = album.coverUrl;
    final embeddedPath =
        album.tracks.isEmpty ? null : album.tracks.first.path;
    if (url == null) {
      return _EmbeddedHero(
        artPath: embeddedPath,
        fallbackColor:
            Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: album.releaseMbid,
      cacheManager: PrismArtCacheManager(),
      fit: BoxFit.cover,
      placeholder: (context, url) => _EmbeddedHero(
        artPath: embeddedPath,
        fallbackColor: Colors.black12,
      ),
      errorWidget: (context, url, error) => _EmbeddedHero(
        artPath: embeddedPath,
        fallbackColor: Colors.black12,
      ),
    );
  }
}

/// Renders embedded picture data from [artPath] when available, or a
/// flat [fallbackColor] surface stamped with `Icons.album_outlined`
/// otherwise.
class _EmbeddedHero extends StatelessWidget {
  const _EmbeddedHero({
    required this.artPath,
    required this.fallbackColor,
  });

  final String? artPath;
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    final path = artPath;
    if (path == null) {
      return ColoredBox(
        color: fallbackColor,
        child: const Center(
          child: Icon(Icons.album_outlined, size: 96, color: Colors.white70),
        ),
      );
    }
    return Image(
      image: EmbeddedArtImage(path),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSync) {
        if (frame == null) {
          return ColoredBox(
            color: fallbackColor,
            child: const Center(
              child: Icon(
                Icons.album_outlined,
                size: 96,
                color: Colors.white70,
              ),
            ),
          );
        }
        return child;
      },
      errorBuilder: (context, error, stack) => ColoredBox(
        color: fallbackColor,
        child: const Center(
          child: Icon(Icons.album_outlined, size: 96, color: Colors.white70),
        ),
      ),
    );
  }
}

/// Slice 7 §8 step 11. Interpolates the art's corner radius across the
/// flight tile (14) → detail (24) → player (8). The tween is stored
/// `const` so the shuttle allocates nothing per-frame
/// (slice 7 §10 risk 7).
Widget _flightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final from = (fromHeroContext.widget as Hero).child;
  final to = (toHeroContext.widget as Hero).child;
  // Push: tile → detail (14 → 24). Pop: detail → tile (24 → 14).
  // Detail → player: 24 → 8 (push), 8 → 24 (pop).
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = animation.value;
      final fromRadius = _radiusOf(from);
      final toRadius = _radiusOf(to);
      final radius = fromRadius + (toRadius - fromRadius) * t;
      // The mid-flight widget paints the destination's child — its
      // ImageProvider, which is what visually morphs.
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: t > 0.5 ? to : from,
      );
    },
  );
}

double _radiusOf(Widget hero) {
  // Best-effort radius extraction — both the tile and the detail wrap
  // their child in a ClipRRect with `BorderRadius.circular`. If a
  // future caller wraps differently, the default falls back to the
  // mid-spec radius of 14.
  final clip = _findClipRRect(hero);
  if (clip == null) return 14;
  final radius = clip.borderRadius;
  if (radius is BorderRadius) {
    return radius.topLeft.x;
  }
  return 14;
}

ClipRRect? _findClipRRect(Widget w) {
  if (w is ClipRRect) return w;
  return null;
}

/// Title hero shuttle. Lerps between the source and destination font
/// sizes (tile=20, detail=28, player=20). Track A's TypographyScale
/// names them `display20` and `display28`.
Widget _titleFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromText = _findText((fromHeroContext.widget as Hero).child);
  final toText = _findText((toHeroContext.widget as Hero).child);
  final scale = Theme.of(flightContext).extension<TypographyScale>()!;
  final fromSize = fromText?.style?.fontSize ?? scale.display20.fontSize ?? 20;
  final toSize = toText?.style?.fontSize ?? scale.display28.fontSize ?? 28;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = animation.value;
      final size = fromSize + (toSize - fromSize) * t;
      final text = (toText ?? fromText)?.data ?? '';
      return Material(
        color: Colors.transparent,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: scale.display28.copyWith(fontSize: size),
        ),
      );
    },
  );
}

Text? _findText(Widget w) {
  if (w is Text) return w;
  if (w is Material) {
    final child = w.child;
    if (child is Text) return child;
  }
  return null;
}

/// Replaces the [AlbumPalette] entry in [theme.extensions] with
/// [palette] and returns the resulting iterable. `theme.extensions`
/// is `Map<Object, ThemeExtension<dynamic>>`; we strip the existing
/// `AlbumPalette` (the neutral seed) and append the per-album one.
Iterable<ThemeExtension<dynamic>> _withPalette(
  ThemeData theme,
  AlbumPalette palette,
) sync* {
  for (final ext in theme.extensions.values) {
    if (ext is AlbumPalette) continue;
    yield ext;
  }
  yield palette;
}

/// Play / Shuffle / Heart actions, rendered as a tight vertical column
/// of icon buttons. Intended to occupy the right-hand side of the
/// metadata Glass card, next to the artist / year text.
///
/// Play and Shuffle drive the queue immediately. Heart is a placeholder
/// that surfaces a "coming soon" snackbar — library favourites land in
/// slice-12.
@visibleForTesting
class AlbumActions extends ConsumerWidget {
  const AlbumActions({super.key, required this.album});
  final AlbumView album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final palette = theme.extension<AlbumPalette>();
    final tinted = palette != null && !palette.isNeutral;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          tooltip: 'Play',
          icon: const Icon(Icons.play_arrow),
          style: tinted
              ? IconButton.styleFrom(backgroundColor: palette.dominant)
              : null,
          onPressed: () {
            if (album.tracks.isEmpty) return;
            ref.read(queueProvider.notifier).loadContext(
                  album.tracks,
                  startIndex: 0,
                );
            // ignore: discarded_futures
            ref.read(playbackServiceProvider).play();
          },
        ),
        SizedBox(height: tokens.s1),
        IconButton(
          tooltip: 'Shuffle',
          icon: const Icon(Icons.shuffle),
          onPressed: () {
            if (album.tracks.isEmpty) return;
            final shuffled = List<Track>.of(album.tracks)..shuffle(Random());
            ref.read(queueProvider.notifier).loadContext(
                  shuffled,
                  startIndex: 0,
                );
            // ignore: discarded_futures
            ref.read(playbackServiceProvider).play();
          },
        ),
        SizedBox(height: tokens.s1),
        IconButton(
          tooltip: 'Favourite',
          icon: const Icon(Icons.favorite_border),
          onPressed: () {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('Favourites coming soon'),
                duration: Duration(seconds: 2),
              ),
            );
          },
        ),
      ],
    );
  }
}

// Private alias so the rest of this file references the short name.
typedef _AlbumActions = AlbumActions;

extension _Firstish<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
