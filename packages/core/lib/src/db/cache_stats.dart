import 'cache_db.dart';
import 'track_status.dart';

/// Snapshot of how many tracks are in each [TrackStatus]. Drives the
/// "Cache stats" Settings row added in slice-4 §8 step 14.
class CacheStats {
  final int ready;
  final int analysisPending;
  final int missingAudio;
  final int embeddings;

  const CacheStats({
    required this.ready,
    required this.analysisPending,
    required this.missingAudio,
    required this.embeddings,
  });

  int get total => ready + analysisPending + missingAudio;

  /// Computes the snapshot off [db]'s writer (sqflite). Cheap — three
  /// indexed COUNTs against `tracks_status` plus a virtual-table
  /// COUNT against `track_embeddings`.
  static Future<CacheStats> compute(CacheDb db) async {
    final rows = await db.writer.rawQuery('''
      SELECT status, COUNT(*) AS n
        FROM tracks
       GROUP BY status
    ''');
    var ready = 0;
    var analysisPending = 0;
    var missingAudio = 0;
    for (final r in rows) {
      final n = (r['n'] as int?) ?? 0;
      switch (TrackStatus.fromValue(r['status'] as String)) {
        case TrackStatus.ready:
          ready = n;
        case TrackStatus.analysisPending:
          analysisPending = n;
        case TrackStatus.missingAudio:
          missingAudio = n;
      }
    }
    final embedCount = db.reader
            .select('SELECT COUNT(*) AS n FROM track_embeddings')
            .firstOrNull?['n'] as int? ??
        0;
    return CacheStats(
      ready: ready,
      analysisPending: analysisPending,
      missingAudio: missingAudio,
      embeddings: embedCount,
    );
  }
}
