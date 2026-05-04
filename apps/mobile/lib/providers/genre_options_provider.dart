import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cache_db_providers.dart';

/// One genre option for the filter sheet's multi-select. `label` is
/// title-cased for display; `storageKeys` is the set of original tag
/// strings that collapse to this label (used in the SQL `IN (...)`
/// clause when building the genre filter).
class GenreOption {
  final String label;
  final List<String> storageKeys;
  const GenreOption({required this.label, required this.storageKeys});

  /// Pure helper: collapses [raws] (raw tag values) into deduped
  /// `GenreOption` entries.
  ///
  /// - Trims each input and drops empty strings.
  /// - Buckets by lower-case form so case variants merge.
  /// - Within each bucket, the display label is the title-cased form
  ///   of the FIRST-SEEN entry (deterministic across re-derivations).
  /// - The bucket's `storageKeys` preserves the original casings in
  ///   insertion order so the SQL `IN (...)` clause can match every
  ///   row.
  /// - Output sorted by the lower-case key (alphabetical).
  static List<GenreOption> collapseFromRaw(Iterable<String> raws) {
    final byLower = <String, List<String>>{};
    final firstSeenForLower = <String, String>{};
    for (final raw in raws) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      byLower.putIfAbsent(lower, () => <String>[]).add(trimmed);
      firstSeenForLower.putIfAbsent(lower, () => trimmed);
    }
    final out = <GenreOption>[];
    final lowers = byLower.keys.toList()..sort();
    for (final lower in lowers) {
      final keys = byLower[lower]!;
      out.add(GenreOption(
        label: _titleCase(firstSeenForLower[lower]!),
        storageKeys: List<String>.unmodifiable(keys),
      ));
    }
    return List<GenreOption>.unmodifiable(out);
  }

  /// Title-case helper that respects hyphen-joined words ("lo-fi" →
  /// "Lo-fi"). Capitalises the first letter of the first word,
  /// lower-cases the rest of the entire string (preserving hyphens).
  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    return '${s.substring(0, 1).toUpperCase()}${s.substring(1).toLowerCase()}';
  }
}

/// Distinct genre options from `cache.db` `tracks.genre`. Excludes null
/// / empty / 'unknown'. Sorted alphabetically by lower-case key (matches
/// the order `collapseFromRaw` produces).
final genreOptionsProvider =
    FutureProvider<List<GenreOption>>((ref) async {
  final db = await ref.watch(cacheDbProvider.future);
  final rows = await db.writer.rawQuery('''
    SELECT DISTINCT genre FROM tracks
     WHERE status = 'ready' AND genre IS NOT NULL
  ''');
  final raws = <String>[];
  for (final r in rows) {
    final raw = (r['genre'] as String?)?.trim();
    if (raw == null || raw.isEmpty) continue;
    if (raw.toLowerCase() == 'unknown') continue;
    raws.add(raw);
  }
  return GenreOption.collapseFromRaw(raws);
});
