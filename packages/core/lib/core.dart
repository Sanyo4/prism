/// Prism core — pure Dart primitives consumed by `packages/playback` and
/// `apps/mobile`. Zero Flutter imports; must be usable by `dart test`
/// without the Flutter SDK.
///
/// Slice 1 surface: [Track] data model, audio-path helpers, the
/// cancelable [LibraryScanner] that yields [ScanEvent]s, and the pure
/// ReplayGain dB↔linear math. `packages/playback` consumes
/// [dbToLinear] to attenuate `just_audio`'s volume.
library;

export 'src/models/track.dart';
export 'src/paths/audio_paths.dart';
export 'src/replay_gain.dart';
export 'src/scanner/cancellation_token.dart';
export 'src/scanner/library_scanner.dart';
export 'src/scanner/scan_event.dart';
// Slice 4 surface — sidecar models, cache DB, ingest pipeline.
export 'src/sidecar/mood_vector.dart';
export 'src/sidecar/sidecar.dart';
export 'src/sidecar/sidecar_reader.dart';
export 'src/sidecar/staleness.dart';
export 'src/db/cache_db.dart';
export 'src/db/cache_stats.dart';
export 'src/db/knn.dart';
export 'src/db/migrations.dart';
export 'src/db/mood_query.dart';
export 'src/db/playlist_repo_impl.dart';
export 'src/db/track_status.dart';
export 'src/db/vec_loader.dart';
export 'src/db/vibe_query.dart';
export 'src/ingest/ingest_coordinator.dart';
export 'src/ingest/upsert.dart';
