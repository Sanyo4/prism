import 'package:flutter/material.dart';

import '../browse/artist_view.dart';

/// Round artist avatar + name. Slice 2 has no MB-sourced avatar URL
/// (`/artist/{mbid}/photo` doesn't exist; CAA only does releases), so
/// we render initials inside a colored circle. Slice 7 polish can
/// trade up to a Last.fm `image` field if we add it.
class ArtistTile extends StatelessWidget {
  const ArtistTile({
    super.key,
    required this.artist,
    required this.onTap,
    this.size = 96,
  });

  final ArtistView artist;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size),
      child: SizedBox(
        width: size + 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: size / 2,
              backgroundColor: _avatarColor(artist.id),
              child: Text(
                _initials(artist.name),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  static Color _avatarColor(String id) {
    // Same FNV hash → HSL pastel shape as elsewhere; kept inline so
    // a slim tile widget doesn't import a browse-view module.
    var h = 2166136261;
    for (final c in id.codeUnits) {
      h = (h ^ c) * 16777619;
      h &= 0xFFFFFFFF;
    }
    final hue = (h % 360).toDouble();
    return _hsl(hue, 0.5, 0.55);
  }

  static Color _hsl(double h, double s, double l) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = h / 60.0;
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
