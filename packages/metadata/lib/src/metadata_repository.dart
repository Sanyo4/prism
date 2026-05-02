import 'dart:convert';

import 'package:prism_core/core.dart';

import 'cache/metadata_dao.dart';
import 'clients/caa_client.dart';
import 'clients/lastfm_client.dart';
import 'clients/mb_client.dart';
import 'models/lastfm_artist_info.dart';
import 'models/mb_recording.dart';
import 'models/mb_release.dart';
import 'models/track_metadata_patch.dart';

/// User-controlled inputs the repository needs to decide whether to
/// run at all. The app builds this from `SharedPreferences`; the
/// metadata layer doesn't import SharedPreferences itself (would drag
/// Flutter in).
///
/// `enabled` && `contactEmail.isNotEmpty` is the only configuration
/// in which we make any MusicBrainz traffic.
class SettingsSnapshot {
  final bool enabled;
  final String contactEmail;
  final String? lastfmApiKey;

  const SettingsSnapshot({
    required this.enabled,
    required this.contactEmail,
    required this.lastfmApiKey,
  });

  bool get configured => enabled && contactEmail.trim().isNotEmpty;
}

/// Snapshot-style settings provider. The BackfillQueue checks this
/// between every request so flipping the toggle mid-run takes effect
/// at the next iteration without restart.
typedef SettingsResolver = SettingsSnapshot Function();

/// Score floor used by the recording-search → release pick path. MB
/// scores below 80 are noisy enough to be a footgun (we'd inherit a
/// wrong release MBID and CAA art). Configurable for tests.
const int kMbScoreFloor = 80;

/// Cache TTL for `caa` cache rows where CAA returned 404. Same as the
/// 1-year hit TTL — release artwork either exists or never does.
const Duration kCaaTtl = CacheTtl.oneYear;

/// The repository is the single composition root for the metadata
/// layer. It owns:
///
/// 1. Settings gate — `configured == false` → never network.
/// 2. Cache short-circuit — every upstream lookup checks `metadata_cache`
///    first; only on miss do we hit the network.
/// 3. Pipeline order — `recording` (preferred) → `release` (fallback)
///    → `caa` (art) → assemble patch filling tag-missing fields only.
/// 4. Persistence — successful patches write `track_meta` so we don't
///    re-query on next launch.
abstract class MetadataRepository {
  Future<TrackMetadataPatch> backfill(Track track);
  Future<LastfmArtistInfo?> artistInfo(String mbid);
  Future<String?> coverArtUrl(String releaseMbid);
  Future<void> clearCache();
  bool get configured;
}

class MetadataRepositoryImpl implements MetadataRepository {
  final MbClient _mb;
  final CaaClient _caa;
  final LastfmClient _lastfm;
  final MetadataDao _dao;
  final SettingsResolver _settings;

  /// Visible for tests — pinned clock, mirrors the DAO's clock injection.
  final DateTime Function() _now;

  MetadataRepositoryImpl({
    required MbClient mbClient,
    required CaaClient caaClient,
    required LastfmClient lastfmClient,
    required MetadataDao dao,
    required SettingsResolver settings,
    DateTime Function()? now,
  })  : _mb = mbClient,
        _caa = caaClient,
        _lastfm = lastfmClient,
        _dao = dao,
        _settings = settings,
        _now = now ?? DateTime.now;

  @override
  bool get configured => _settings().configured;

  @override
  Future<void> clearCache() => _dao.clearAll();

  @override
  Future<TrackMetadataPatch> backfill(Track track) async {
    final settings = _settings();
    if (!settings.configured) return TrackMetadataPatch.empty;

    // Cheap skip: an existing track_meta row means we've tried this
    // path before. The BackfillQueue is the policy owner for "should
    // we retry?" — repository only honours its hit/miss recorded state.
    final existing = await _dao.readTrackMeta(track.path);
    if (existing != null && existing.patchedAt > 0) {
      return _patchFromTrackMetaCache(track, existing);
    }

    // 1. Recording search (preferred).
    var patch = TrackMetadataPatch.empty;
    String? recordingMbid;
    String? releaseMbid;
    String? artistMbid;
    String? coverUrl;
    String? lastError;

    final title = track.title;
    final album = track.album;
    final artistTag = track.artist;
    try {
      if (title != null && title.isNotEmpty) {
        final hits = await _mb.searchRecording(
          title: title,
          artist: artistTag,
          limit: 5,
        );
        final winner = hits
            .where((MbRecording h) => h.score >= kMbScoreFloor)
            .firstOrNullPrism;
        if (winner != null) {
          recordingMbid = winner.mbid;
          artistMbid = winner.artistMbid;
          // Pick the first Official release; fall back to the first.
          final rels = winner.releases;
          if (rels.isNotEmpty) {
            final official = rels.firstWhere(
              (r) => r.status == 'Official',
              orElse: () => rels.first,
            );
            releaseMbid = official.mbid;
            patch = _mergePatchFromRecording(track,
                recording: winner, release: official);
            await _dao.upsertCache(
              kind: 'recording',
              mbid: recordingMbid,
              payload: jsonEncode({
                'mbid': recordingMbid,
                'release_mbid': releaseMbid,
                'artist_mbid': artistMbid,
              }),
              ttl: CacheTtl.oneYear,
            );
          }
        }
      }

      // 2. Release fallback when recording-search produced nothing.
      if (releaseMbid == null && album != null && album.isNotEmpty) {
        final hits = await _mb.searchRelease(
          album: album,
          artist: artistTag,
          limit: 5,
        );
        final winner = hits
            .where((MbRelease h) => h.score >= kMbScoreFloor)
            .firstOrNullPrism;
        if (winner != null) {
          releaseMbid = winner.mbid;
          artistMbid ??= winner.artistMbid;
          patch = _mergePatchFromRelease(track, release: winner);
        }
      }

      // 3. CAA front art when we have a release.
      if (releaseMbid != null) {
        coverUrl = await coverArtUrl(releaseMbid);
        if (coverUrl != null) {
          patch = _withCover(patch, coverUrl);
        }
      }
    } on Exception catch (e) {
      lastError = e.toString();
    }

    final attempted = (existing?.attemptCount ?? 0) + 1;
    final patchedAt = patch.isNotEmpty ? _now().millisecondsSinceEpoch : 0;
    await _dao.upsertTrackMeta(
      path: track.path,
      recordingMbid: recordingMbid,
      releaseMbid: releaseMbid,
      artistMbid: artistMbid,
      patchedAt: patchedAt,
      attemptCount: attempted,
      lastError: lastError,
    );
    return patch;
  }

  @override
  Future<String?> coverArtUrl(String releaseMbid) async {
    final hit = await _dao.readCache('caa', releaseMbid);
    if (hit != null) {
      // payload '{}' = cached miss; string url means cached hit.
      final decoded = jsonDecode(hit.payload);
      if (decoded is Map && decoded['url'] is String) {
        return decoded['url'] as String;
      }
      return null;
    }
    final art = await _caa.frontUrl(releaseMbid);
    await _dao.upsertCache(
      kind: 'caa',
      mbid: releaseMbid,
      payload: jsonEncode(art == null ? {} : {'url': art.url}),
      ttl: kCaaTtl,
    );
    return art?.url;
  }

  @override
  Future<LastfmArtistInfo?> artistInfo(String mbid) async {
    final hit = await _dao.readCache('lastfm_artist', mbid);
    if (hit != null) {
      // We cache the full upstream JSON envelope. Re-parse here.
      final decoded = jsonDecode(hit.payload);
      if (decoded is Map<String, Object?>) {
        return LastfmArtistInfo.fromJson(decoded);
      }
      return null;
    }
    final info = await _lastfm.artistInfo(mbid);
    if (info != null) {
      // Wrap in the same shape `LastfmArtistInfo.fromJson` expects so
      // a cache replay works without a side parser.
      final payload = jsonEncode({
        'artist': {
          'mbid': info.mbid,
          'name': info.name,
          'bio': {'content': info.bio},
          'tags': {'tag': info.tags.map((t) => {'name': t}).toList()},
        }
      });
      await _dao.upsertCache(
        kind: 'lastfm_artist',
        mbid: mbid,
        payload: payload,
        ttl: CacheTtl.thirtyDays,
      );
    }
    return info;
  }

  // --- patch composition -------------------------------------------------
  //
  // We split into two overloads rather than a single dynamic-typed
  // method so the static type checker enforces the field shape. The
  // recording variant carries track/disc numbers; the release-only
  // variant doesn't, and the fields default to null instead of leaking
  // a NoSuchMethodError at runtime.

  /// Patch from a `/recording` win + chosen release. Tag-embedded
  /// values still win — we never overwrite a non-null tag.
  TrackMetadataPatch _mergePatchFromRecording(
    Track track, {
    required MbRecording recording,
    required MbRecordingRelease release,
  }) {
    return TrackMetadataPatch(
      title: track.title == null ? recording.title : null,
      artist: track.artist == null ? recording.artistName : null,
      albumArtist: track.albumArtist == null ? recording.artistName : null,
      album: track.album == null ? release.title : null,
      year: track.year == null ? release.year : null,
      trackNo: track.trackNo == null ? release.trackNo : null,
      discNo: track.discNo == null ? release.discNo : null,
      recordingMbid: recording.mbid,
      releaseMbid: release.mbid,
      artistMbid: recording.artistMbid,
    );
  }

  /// Patch from the release-only fallback. No track/disc numbers
  /// (the release search hit doesn't carry them).
  TrackMetadataPatch _mergePatchFromRelease(
    Track track, {
    required MbRelease release,
  }) {
    return TrackMetadataPatch(
      artist: track.artist == null ? release.artistName : null,
      albumArtist: track.albumArtist == null ? release.artistName : null,
      album: track.album == null ? release.title : null,
      year: track.year == null ? release.year : null,
      releaseMbid: release.mbid,
      artistMbid: release.artistMbid,
    );
  }

  TrackMetadataPatch _withCover(TrackMetadataPatch p, String url) =>
      TrackMetadataPatch(
        title: p.title,
        artist: p.artist,
        albumArtist: p.albumArtist,
        album: p.album,
        genre: p.genre,
        year: p.year,
        trackNo: p.trackNo,
        discNo: p.discNo,
        recordingMbid: p.recordingMbid,
        releaseMbid: p.releaseMbid,
        artistMbid: p.artistMbid,
        coverUrl: url,
      );

  Future<TrackMetadataPatch> _patchFromTrackMetaCache(
    Track track,
    TrackMetaRow row,
  ) async {
    // Recompose just the cover URL — the rest of the patch is already
    // baked into the in-memory Track via prior browse-row updates.
    String? cover;
    if (row.releaseMbid != null) {
      cover = await coverArtUrl(row.releaseMbid!);
    }
    return TrackMetadataPatch(
      recordingMbid: row.recordingMbid,
      releaseMbid: row.releaseMbid,
      artistMbid: row.artistMbid,
      coverUrl: cover,
    );
  }
}

extension _Firstish<E> on Iterable<E> {
  /// Local equivalent of `firstOrNull` — Dart 3.x `package:collection`
  /// ships one but we keep the metadata package's deps tight so we
  /// don't drag the whole package in for a one-line helper.
  E? get firstOrNullPrism {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
