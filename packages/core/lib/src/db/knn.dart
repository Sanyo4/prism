import 'dart:typed_data';

import 'cache_db.dart';

/// One row from a kNN query: a track id and its L2 distance from the
/// seed embedding. Ordered ascending — distance 0 means exact match
/// (the seed itself, filtered out before return).
class KnnHit {
  final int trackId;
  final double distance;
  const KnnHit(this.trackId, this.distance);
}

/// Returns up to [k] nearest neighbours of [seedTrackId] in
/// `track_embeddings`, ordered by ascending L2 distance, excluding the
/// seed itself and any non-`ready` rows.
///
/// Implementation note: vec0 doesn't natively support a "join then
/// MATCH" form, so we do two queries — fetch the seed embedding bytes
/// first, then run a single MATCH query — and join in a final
/// `tracks.status='ready'` filter pass on the small result set.
Future<List<KnnHit>> runKnnByEmbedding(
  CacheDb db, {
  required int seedTrackId,
  int k = 25,
}) async {
  // 1. Pull the seed embedding from the FFI handle. vec0 returns
  // BLOB-shaped bytes; we re-bind them directly into the MATCH
  // query.
  final seedRows = db.reader.select(
    'SELECT embedding FROM track_embeddings WHERE track_id = ?',
    [seedTrackId],
  );
  if (seedRows.isEmpty) return const [];
  final seedBytes = seedRows.first['embedding'] as Uint8List;

  // 2. Pull k+1 hits (seed will sit at position 0 with d=0); we'll
  // strip it below.
  final fetch = k + 1;
  final hitRows = db.reader.select(
    '''
    SELECT track_id, distance
      FROM track_embeddings
     WHERE embedding MATCH ? AND k = ?
     ORDER BY distance
    ''',
    [seedBytes, fetch],
  );
  if (hitRows.isEmpty) return const [];

  // 3. Filter to status='ready' rows (excluding the seed). Single
  // batched lookup keeps this O(k) round-trips down to one.
  final candidateIds = <int>[
    for (final r in hitRows)
      if ((r['track_id'] as int) != seedTrackId) r['track_id'] as int,
  ];
  if (candidateIds.isEmpty) return const [];
  final placeholders = List.filled(candidateIds.length, '?').join(',');
  final readyRows = await db.writer.rawQuery(
    'SELECT id FROM tracks WHERE status = \'ready\' AND id IN ($placeholders)',
    candidateIds,
  );
  final readyIds = <int>{for (final r in readyRows) r['id'] as int};

  final out = <KnnHit>[];
  for (final r in hitRows) {
    final id = r['track_id'] as int;
    if (id == seedTrackId) continue;
    if (!readyIds.contains(id)) continue;
    out.add(KnnHit(id, (r['distance'] as num).toDouble()));
    if (out.length == k) break;
  }
  return out;
}
