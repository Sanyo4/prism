/// Where a row sits in the ingest lifecycle.
///
/// All mood / vibe / kNN queries filter `status='ready'`. Other states
/// keep the row visible for plain library browsing + playback (so the
/// user can still play a freshly-synced file before its sidecar
/// arrives) but hide it from sonic-aware surfaces.
enum TrackStatus {
  /// Tagged audio + matching sidecar present and validated.
  ready('ready'),

  /// Tagged audio is present, but the sidecar is missing, stale, or
  /// the canonical sibling lost to a Syncthing conflict copy. Plays
  /// via tag RG; excluded from mood/vibe/kNN.
  analysisPending('analysis_pending'),

  /// Audio file vanished between scans (deletion / move / unmount).
  /// Row kept until the next ingest reconciliation might add it back.
  /// Hidden from playback contexts that expect a live file.
  missingAudio('missing_audio');

  /// Discriminator string written into the `tracks.status` TEXT column.
  /// Stable on disk — never rename without a migration.
  final String value;
  const TrackStatus(this.value);

  /// Inverse of [value]. Returns [TrackStatus.analysisPending] for any
  /// unknown string so a forward-compat row introduced by a future
  /// slice doesn't crash the reader.
  static TrackStatus fromValue(String raw) {
    for (final s in TrackStatus.values) {
      if (s.value == raw) return s;
    }
    return TrackStatus.analysisPending;
  }
}
