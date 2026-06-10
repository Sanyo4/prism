/// Why a sidecar can't be promoted to `status='ready'`. Each variant
/// maps to a row that stays in `tracks` (so playback still works via
/// tag RG) but is excluded from mood / vibe / kNN until the desktop
/// indexer refreshes and Syncthing propagates.
///
/// The slice-4 plan §10 risks 5 (conflict copies) and 6 (schema bump)
/// expand on the long-tail recovery for each of these.
enum StalenessReason {
  /// `schema_version != kCurrentSidecarSchemaVersion`. Indexer is
  /// behind or ahead; reader pretends the sidecar isn't there.
  schemaMismatch,

  /// `analyzer_models` is disjoint from
  /// [kCompatibleAnalyzerModels] — the indexer ran with a different
  /// model set than slice 4 understands. Embedding shape may still be
  /// 1280-dim, but mood/genre cuts could be from a non-comparable head.
  analyzerMismatch,

  /// JSON couldn't be parsed at all (unterminated, wrong types,
  /// malformed UTF-8, etc.). Treat as "no sidecar" for ingest.
  malformedJson,

  /// Filename matches `*.sync-conflict-*.sonic.json` — Syncthing
  /// dropped a conflict copy because two devices wrote concurrently.
  /// The canonical sibling wins; this one is parked.
  conflictCopy,
}
