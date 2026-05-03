import 'dart:io';
import 'dart:typed_data';

import 'package:prism_core/core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Resolve the linux vec0.so committed under apps/mobile/native. Tests
/// run via `dart test` from the repo root by default; we also accept
/// the packages/core CWD that some IDE runners use.
String resolveLinuxVec0Path() {
  final candidates = <String>[
    'apps/mobile/native/linux/x86_64/vec0.so',
    '../../apps/mobile/native/linux/x86_64/vec0.so',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return File(c).absolute.path;
  }
  throw FileSystemException(
    'committed vec0.so not found; tried ${candidates.join(", ")}',
    candidates.first,
  );
}

/// Opens a fresh in-process sqflite_common_ffi-backed CacheDb against a
/// per-test temp file. Returns the DB and a teardown closure.
Future<({CacheDb db, Future<void> Function() teardown})> openFreshTestDb() async {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;
  final dir = Directory.systemTemp.createTempSync('prism-cache-');
  final dbPath = '${dir.path}/cache.db';
  final db = await CacheDb.open(
    factory: factory,
    path: dbPath,
    vec0Path: resolveLinuxVec0Path(),
  );
  return (
    db: db,
    teardown: () async {
      await db.close();
      // Best-effort cleanup; Linux temp eviction handles stragglers.
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    },
  );
}

/// Builds a synthetic 1280-dim embedding seeded by [seed]. Each
/// dimension is `(seed + i) / 1280` mod 1, so seeds N apart produce
/// vectors at L2 distance ≈ √(N²/1280) — useful for asserting
/// ordering in kNN tests.
List<double> syntheticEmbedding(double seed) {
  return List<double>.generate(1280, (i) => ((seed + i) % 1280) / 1280.0);
}

/// Encodes a [List<double>] to vec0's binary blob shape.
Uint8List embeddingBlob(List<double> values) {
  final out = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    out.setFloat32(i * 4, values[i], Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Writes a row directly via sqflite for tests that don't want to go
/// through the full ingest pipeline. Returns the new tracks.id.
Future<int> insertRawTrackRow(
  Database writer, {
  required String path,
  required String audioSha1,
  String status = 'ready',
  String? title,
  String? artist,
  String? album,
  String? key,
  int? year,
  double? bpm,
  double? danceability,
  double? voiceInstrumental,
  double? moodHappy,
  double? moodSad,
  double? moodAggressive,
  double? moodRelaxed,
  double? moodParty,
  double? replaygainTrackDb,
  int? playCount,
  int? addedAt,
}) async {
  final id = await writer.insert('tracks', {
    'path': path,
    'audio_sha1': audioSha1,
    'status': status,
    'title': title,
    'artist': artist,
    'album': album,
    'key': key,
    'year': year,
    'bpm': bpm,
    'danceability': danceability,
    'voice_instrumental': voiceInstrumental,
    'mood_happy': moodHappy,
    'mood_sad': moodSad,
    'mood_aggressive': moodAggressive,
    'mood_relaxed': moodRelaxed,
    'mood_party': moodParty,
    'replaygain_track_db': replaygainTrackDb,
    'play_count': playCount ?? 0,
    'added_at': addedAt ?? DateTime.now().millisecondsSinceEpoch,
  });
  return id;
}
