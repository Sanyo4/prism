import 'dart:typed_data';

import 'package:sqflite_common/sqflite.dart';

import '../models/track.dart';
import '../sidecar/sidecar.dart';
import '../db/track_status.dart';

/// Builds the `tracks` row for a [Track] + optional [Sidecar] pair and
/// returns the column→value map ready to feed into a `sqflite` upsert.
///
/// When [sidecar] is `null` we still emit a row (so playback works on
/// tag-only files) but with `status='analysis_pending'` and every
/// sonic column nulled out.
Map<String, Object?> buildTrackRow({
  required Track track,
  required Sidecar? sidecar,
  required String? sidecarPath,
  required int? sidecarMtimeMs,
  required TrackStatus status,
  required int addedAtMs,
}) {
  return <String, Object?>{
    'path': track.path,
    'audio_sha1': sidecar?.audioSha1 ?? '',
    'sidecar_path': sidecarPath,
    'sidecar_mtime': sidecarMtimeMs,
    'title': track.title,
    'artist': track.artist,
    'album_artist': track.albumArtist,
    'album': track.album,
    'track_no': track.trackNo,
    'disc_no': track.discNo,
    'year': track.year,
    'genre': track.genre,
    'duration_sec':
        sidecar?.durationSec ?? _trackDurationSec(track.duration),
    'bpm': sidecar?.bpm,
    'key': sidecar?.key,
    'loudness_lufs': sidecar?.loudnessLufs,
    'replaygain_track_db':
        sidecar?.replaygainTrackDb ?? track.replayGainTrackDb,
    'replaygain_album_db':
        sidecar?.replaygainAlbumDb ?? track.replayGainAlbumDb,
    'danceability': sidecar?.danceability,
    'voice_instrumental': sidecar?.voiceInstrumental,
    'mood_happy': sidecar?.mood.happy,
    'mood_sad': sidecar?.mood.sad,
    'mood_aggressive': sidecar?.mood.aggressive,
    'mood_relaxed': sidecar?.mood.relaxed,
    'mood_party': sidecar?.mood.party,
    'added_at': addedAtMs,
    'status': status.value,
    // Stored as a comma-separated string for resume comparison;
    // JSON-array would also work but adds parser cost on read.
    'analyzer_models': sidecar?.analyzerModels.join(','),
    'schema_version': sidecar?.schemaVersion,
  };
}

double? _trackDurationSec(Duration? d) {
  final ms = d?.inMilliseconds;
  return ms == null ? null : ms / 1000.0;
}

/// Encodes a 1280-dim embedding into the binary blob shape vec0
/// accepts: little-endian IEEE-754 float32, 5120 bytes total.
///
/// Verified by `dart run packages/core/example/probe_vec0.dart` (now
/// removed) — matches the distances vec0 reports for the equivalent
/// `'[a,b,...]'` string form.
Uint8List embeddingBytes(List<double> embedding) {
  if (embedding.length != 1280) {
    throw ArgumentError(
      'embedding must be length 1280, got ${embedding.length}',
    );
  }
  final out = ByteData(1280 * 4);
  for (var i = 0; i < 1280; i++) {
    out.setFloat32(i * 4, embedding[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Upserts one row into `tracks` (keyed on `path`) inside [txn] and
/// returns the resulting `tracks.id`. Caller is responsible for
/// inserting / updating the matching `track_embeddings` row outside
/// the sqflite transaction (vec0 expects a separate write path —
/// transactional vec0 inserts work in our setup, but we wrap the
/// embedding write in a separate execute call for clarity).
Future<int> upsertTrackRow(
  Transaction txn, {
  required Map<String, Object?> row,
}) async {
  // sqflite's `Transaction` doesn't expose RETURNING in a
  // version-portable way, so we do an explicit lookup. UNIQUE on
  // `path` makes both branches O(1).
  final existing = await txn.query(
    'tracks',
    columns: const ['id'],
    where: 'path = ?',
    whereArgs: [row['path']],
    limit: 1,
  );
  if (existing.isEmpty) {
    final id = await txn.insert('tracks', row);
    return id;
  }
  final id = existing.first['id'] as int;
  await txn.update(
    'tracks',
    row,
    where: 'id = ?',
    whereArgs: [id],
  );
  return id;
}

/// Inserts or replaces the embedding row for [trackId].
///
/// vec0 doesn't honour SQLite's `INSERT OR REPLACE` conflict resolution
/// — its virtual-table layer rejects the second insert with a UNIQUE
/// constraint error rather than discarding the existing row first
/// (verified empirically against v0.1.9). Idiomatic shape is "delete
/// then insert" wrapped in the same transaction the caller owns.
Future<void> upsertEmbedding(
  Transaction txn, {
  required int trackId,
  required Uint8List embedding,
}) async {
  await txn.execute(
    'DELETE FROM track_embeddings WHERE track_id = ?',
    [trackId],
  );
  await txn.execute(
    'INSERT INTO track_embeddings(track_id, embedding) VALUES(?, ?)',
    [trackId, embedding],
  );
}

/// Removes the embedding row for [trackId] when a previously-`ready`
/// track regresses to `analysis_pending` or `missing_audio`. Keeps
/// the `track_embeddings` table from accumulating orphans (slice-4
/// §11 item 8).
Future<void> deleteEmbedding(Transaction txn, int trackId) async {
  await txn.execute(
    'DELETE FROM track_embeddings WHERE track_id = ?',
    [trackId],
  );
}
