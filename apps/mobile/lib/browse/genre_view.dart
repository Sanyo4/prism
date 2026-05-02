import 'dart:ui';

import 'package:prism_core/core.dart';

/// Genre tile. `accent` is a deterministic pastel derived from a hash
/// of [id], so re-renders pick the same colour for "shoegaze" without
/// any persisted state. Slice 7 swaps to palette-aware tints; this
/// one keeps the tile readable in either light/dark Material 3.
class GenreView {
  /// Lower-cased + trimmed label used as the Riverpod key.
  final String id;

  /// Title-cased display label.
  final String label;

  final int trackCount;
  final int artistCount;

  /// Deterministic pastel — used as the fallback gradient on the tile
  /// when slice 4 has no mood embedding to colour by.
  final Color accent;

  const GenreView({
    required this.id,
    required this.label,
    required this.trackCount,
    required this.artistCount,
    required this.accent,
  });
}

/// Pure derivation: counts tracks + distinct artists per `genre`,
/// drops empty / literal `'Unknown'` genres so the surface stays
/// signal-only.
///
/// Sort: track count descending, then label ascending — the largest
/// pile sits top-left, breaking ties alphabetically.
List<GenreView> indexGenres(List<Track> tracks) {
  final counts = <String, int>{};
  final artistsBy = <String, Set<String>>{};
  final labelById = <String, String>{};
  for (final t in tracks) {
    final raw = t.genre?.trim();
    if (raw == null || raw.isEmpty) continue;
    if (raw.toLowerCase() == 'unknown') continue;
    final id = raw.toLowerCase();
    labelById.putIfAbsent(id, () => _titleCase(raw));
    counts.update(id, (c) => c + 1, ifAbsent: () => 1);
    final aid = (t.albumArtist?.trim().isNotEmpty ?? false)
        ? t.albumArtist!.trim().toLowerCase()
        : (t.artist?.trim().toLowerCase() ?? '');
    if (aid.isNotEmpty) {
      artistsBy.putIfAbsent(id, () => {}).add(aid);
    }
  }
  return counts.entries
      .map((e) => GenreView(
            id: e.key,
            label: labelById[e.key] ?? e.key,
            trackCount: e.value,
            artistCount: artistsBy[e.key]?.length ?? 0,
            accent: _accentFor(e.key),
          ))
      .toList()
    ..sort((a, b) {
      if (a.trackCount != b.trackCount) {
        return b.trackCount.compareTo(a.trackCount);
      }
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
}

String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty
          ? w
          : '${w.substring(0, 1).toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

/// Deterministic pastel: hash → HSL → Color. Why HSL: lets us pin the
/// saturation + lightness so any genre lands in the same readability
/// band, regardless of how the hash distributes hue.
Color _accentFor(String id) {
  // FNV-1a 32-bit. Cheap, stable across Dart VM/Web, and "good enough"
  // for tile colour distribution.
  var h = 2166136261;
  for (final c in id.codeUnits) {
    h = (h ^ c) * 16777619;
    h &= 0xFFFFFFFF;
  }
  final hue = h % 360;
  return _hslToColor(hue.toDouble(), 0.55, 0.7);
}

Color _hslToColor(double h, double s, double l) {
  // Standard CSS-style HSL→RGB.
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
