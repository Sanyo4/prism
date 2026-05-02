import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../browse/album_view.dart';
import 'prism_art_cache_manager.dart';

/// One album tile: cover art on top, two-line title/artist beneath.
/// Tap routes to `AlbumDetailScreen` via the static `route` helper.
///
/// Cover-art handling:
/// - `coverUrl != null`: `CachedNetworkImage` with `cacheKey =
///   releaseMbid` so re-derivations of the URL keep the same disk
///   bucket. Placeholder + error widgets fall back to the gradient
///   tile so a slow network never leaves the row blank.
/// - `coverUrl == null`: gradient based on the album id hash; matches
///   the look of slice 7's polished "art-pending" state.
class AlbumTile extends StatelessWidget {
  const AlbumTile({
    super.key,
    required this.album,
    required this.onTap,
    this.size = 156,
  });

  final AlbumView album;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: _Cover(
                  coverUrl: album.coverUrl,
                  cacheKey: album.releaseMbid,
                  fallbackSeed: album.id,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            Text(
              album.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({
    required this.coverUrl,
    required this.fallbackSeed,
    this.cacheKey,
  });

  final String? coverUrl;
  final String? cacheKey;
  final String fallbackSeed;

  @override
  Widget build(BuildContext context) {
    final url = coverUrl;
    if (url == null) {
      return _GradientFallback(seed: fallbackSeed);
    }
    return CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      cacheManager: PrismArtCacheManager(),
      fit: BoxFit.cover,
      placeholder: (context, url) => _GradientFallback(seed: fallbackSeed),
      errorWidget: (context, url, error) =>
          _GradientFallback(seed: fallbackSeed),
    );
  }
}

class _GradientFallback extends StatelessWidget {
  const _GradientFallback({required this.seed});
  final String seed;

  @override
  Widget build(BuildContext context) {
    // Cheap deterministic colour pair from the seed hash. Slice 7's
    // palette pass replaces this with an image-derived gradient when
    // art is present; for null-art tiles the same pastel fallback
    // ships through to slice 7.
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
          colors: [_pastel(hueA), _pastel(hueB)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.album_outlined, size: 48, color: Colors.white70),
      ),
    );
  }

  Color _pastel(double hue) {
    // Same HSL → RGB shape as `genre_view.dart` — kept inline because
    // we want to avoid a tile-widget importing a browse-view module.
    const s = 0.5;
    const l = 0.7;
    final c = (1 - (2 * l - 1).abs()) * s;
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
