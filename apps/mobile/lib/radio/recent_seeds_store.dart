/// Persistent LRU of the last three radio seeds the user started.
///
/// Why three: matches the slice 5 §2 spec (`RecentSeedsStore` keeps at
/// most three seeds, LRU). The Home `RadioHomeCard`, retired in slice 10,
/// used to paginate through these — three is the densest set that still
/// fits one row of the Pixel 9 Pro Fold portrait without horizontal
/// scrolling. The store remains for slice-5 long-press re-entry semantics.
///
/// Storage: a single JSON-encoded list under one shared-preferences
/// key. Survives app restart; cleared only on `SharedPreferences.clear()`
/// which Prism never calls.
///
/// Why not put this in a Riverpod provider directly: `SharedPreferences`
/// init is async and we don't want every consumer to live in an
/// `AsyncValue`. The store is a thin wrapper that takes a
/// `SharedPreferences` instance and exposes synchronous reads /
/// idempotent writes; the Riverpod layer caches the resolved store.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One row in [RecentSeedsStore]. Matches §2's JSON shape verbatim:
/// `{kind: 'track'|'album'|'artist', ref: [id-or-key], label:
/// [display-label], lastUsedIso: [iso8601]}`.
class RecentSeedEntry {
  /// `'track'`, `'album'`, or `'artist'`.
  final String kind;

  /// Stable ref: track id (string-encoded), album key, or artist name.
  /// Engine providers parse this back according to [kind].
  final String ref;

  /// Display label rendered on the Home card.
  final String label;

  /// When this seed was last selected. Used to LRU-sort on insert.
  final DateTime lastUsedAt;

  const RecentSeedEntry({
    required this.kind,
    required this.ref,
    required this.label,
    required this.lastUsedAt,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'ref': ref,
        'label': label,
        'lastUsedIso': lastUsedAt.toIso8601String(),
      };

  static RecentSeedEntry? fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final ref = json['ref'];
    final label = json['label'];
    final iso = json['lastUsedIso'];
    if (kind is! String || ref is! String || label is! String) return null;
    if (iso is! String) return null;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return null;
    if (kind != 'track' && kind != 'album' && kind != 'artist') return null;
    return RecentSeedEntry(
      kind: kind,
      ref: ref,
      label: label,
      lastUsedAt: parsed,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentSeedEntry &&
          other.kind == kind &&
          other.ref == ref &&
          other.label == label &&
          other.lastUsedAt == lastUsedAt);

  @override
  int get hashCode => Object.hash(kind, ref, label, lastUsedAt);
}

/// LRU-3 store backed by [SharedPreferences].
///
/// Equality keying: two entries are "the same seed" when their
/// `(kind, ref)` tuple matches. Re-inserting bumps `lastUsedAt` and
/// moves the entry to the head; the tail is evicted once the list
/// would exceed [capacity].
class RecentSeedsStore {
  RecentSeedsStore({
    required SharedPreferences prefs,
    this.capacity = 3,
    this.storageKey = 'prism.radio.recent_seeds',
  }) : _prefs = prefs;

  final SharedPreferences _prefs;

  /// Cap for the number of stored entries. Default 3 per slice 5 §2.
  final int capacity;

  /// Shared-prefs key the JSON list lives under.
  final String storageKey;

  /// Reads the persisted list. Returns an empty list when the key is
  /// absent or the stored JSON is malformed (defensive: a corrupt
  /// blob shouldn't take the Home screen down).
  List<RecentSeedEntry> load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const <RecentSeedEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <RecentSeedEntry>[];
      final entries = <RecentSeedEntry>[];
      for (final element in decoded) {
        if (element is Map<String, Object?>) {
          final entry = RecentSeedEntry.fromJson(element);
          if (entry != null) entries.add(entry);
        } else if (element is Map) {
          final entry = RecentSeedEntry.fromJson(
            Map<String, Object?>.from(element),
          );
          if (entry != null) entries.add(entry);
        }
      }
      return entries;
    } catch (_) {
      return const <RecentSeedEntry>[];
    }
  }

  /// Inserts [entry] at the head, dropping any prior entry with the
  /// same `(kind, ref)` and evicting the LRU tail when the list grows
  /// past [capacity]. Returns the resulting list.
  Future<List<RecentSeedEntry>> upsert(RecentSeedEntry entry) async {
    final current = load();
    final filtered = <RecentSeedEntry>[
      entry,
      ...current.where((e) => !(e.kind == entry.kind && e.ref == entry.ref)),
    ];
    final trimmed = filtered.length <= capacity
        ? filtered
        : filtered.sublist(0, capacity);
    await _persist(trimmed);
    return trimmed;
  }

  Future<void> _persist(List<RecentSeedEntry> list) async {
    final encoded = jsonEncode(list.map((e) => e.toJson()).toList());
    await _prefs.setString(storageKey, encoded);
  }
}
