import 'package:prism_metadata/metadata.dart';

/// Stream event emitted by the BackfillQueue: a [TrackMetadataPatch]
/// applied to a single audio file path.
///
/// Why we wrap rather than emit `(path, patch)` records: the merger in
/// `metadata_providers.dart` listens with `await for`; carrying the
/// path on a small named class keeps the listener readable and lets us
/// add a `source` field later (slice 4 will distinguish "MB backfill"
/// from "sidecar ingest").
class TrackPatch {
  /// Absolute filesystem path of the track this patch applies to.
  final String path;

  /// The patch payload from `MetadataRepository.backfill`. Always
  /// non-empty when the queue emits — the queue swallows
  /// `TrackMetadataPatch.empty` so listeners aren't woken for nothing.
  final TrackMetadataPatch patch;

  const TrackPatch({required this.path, required this.patch});
}
