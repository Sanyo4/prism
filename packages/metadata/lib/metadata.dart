/// Prism metadata — pure-Dart upstream fetchers + on-disk cache for the
/// online-metadata backfill that runs after `LibraryScanner.scan`
/// completes. This package is the only place in the app that talks to
/// MusicBrainz; it owns the 1 req/sec `Pacer`, the `User-Agent` header,
/// and the cache shape.
///
/// Slice 2 surface (exports added as each step lands):
/// - [Pacer] / [Pacer503Exception] — the single global rate limiter.
/// - [MbClient], [CaaClient], [LastfmClient] — read-only HTTP clients.
/// - [MetadataRepository] — backfill + lazy artist info + clearCache.
/// - [TrackMetadataPatch] — the value object the app applies to a Track.
/// - Mb/Caa/Lastfm response models for parsed upstream payloads.
/// - [MetadataDb] / [MetadataDao] — `metadata_cache` + `track_meta`
///   (schema v1; slice 4 bumps to v2 and adds `tracks` + `track_embeddings`).
///
/// `packages/metadata` has zero Flutter imports — testable under plain
/// `dart test` via `sqflite_common_ffi`. The app composes the
/// repository, hands it a SettingsSnapshot, and consumes the patch
/// stream from `apps/mobile/lib/backfill/`.
library;

export 'src/cache/metadata_dao.dart';
export 'src/cache/metadata_db.dart';
export 'src/clients/caa_client.dart';
export 'src/clients/lastfm_client.dart';
export 'src/clients/mb_client.dart';
export 'src/metadata_repository.dart';
export 'src/models/caa_art.dart';
export 'src/models/lastfm_artist_info.dart';
export 'src/models/mb_artist.dart';
export 'src/models/mb_recording.dart';
export 'src/models/mb_release.dart';
export 'src/models/track_metadata_patch.dart';
export 'src/pacer.dart';
