import 'dart:io';

import '../db/cache_db.dart';
import '../db/track_status.dart';
import '../scanner/scan_event.dart';
import '../sidecar/sidecar_reader.dart';
import 'upsert.dart';

/// Outcome of one ingest run, surfaced in Settings + verification
/// matrix item 2.
class IngestSummary {
  /// Tracks that landed in `status='ready'` (sidecar present, valid,
  /// analyzer-models compatible).
  final int ready;

  /// Tracks visible to the scanner but missing/stale/conflict-copy
  /// sidecars.
  final int analysisPending;

  /// Tracks rows that were in the cache but not in this scan — flipped
  /// to `missing_audio`.
  final int missingAudio;

  /// Audio files that failed to ingest at all (Sidecar `read` threw a
  /// non-recoverable error before classification, etc.). Should always
  /// be 0 — the reader doesn't throw — but kept for symmetry.
  final int errors;

  const IngestSummary({
    required this.ready,
    required this.analysisPending,
    required this.missingAudio,
    required this.errors,
  });

  IngestSummary copyWith({
    int? ready,
    int? analysisPending,
    int? missingAudio,
    int? errors,
  }) =>
      IngestSummary(
        ready: ready ?? this.ready,
        analysisPending: analysisPending ?? this.analysisPending,
        missingAudio: missingAudio ?? this.missingAudio,
        errors: errors ?? this.errors,
      );

  static const empty = IngestSummary(
    ready: 0,
    analysisPending: 0,
    missingAudio: 0,
    errors: 0,
  );
}

/// One streaming progress notification from [IngestCoordinator.run].
sealed class IngestEvent {
  const IngestEvent();
}

final class IngestProgress extends IngestEvent {
  final int processed;
  final int totalSoFar;
  const IngestProgress({required this.processed, required this.totalSoFar});
}

final class IngestComplete extends IngestEvent {
  final IngestSummary summary;
  const IngestComplete(this.summary);
}

/// Drives the scan → upsert pipeline. Consumes a `Stream<ScanEvent>`
/// from `LibraryScanner.scan` and applies sidecar-driven state to a
/// [CacheDb].
class IngestCoordinator {
  IngestCoordinator({
    required this.cache,
    SidecarReader? reader,
    DateTime Function()? now,
  })  : _reader = reader ?? const SidecarReader(),
        _now = now ?? DateTime.now;

  final CacheDb cache;
  final SidecarReader _reader;
  final DateTime Function() _now;

  /// Run one ingest pass. Yields [IngestProgress] periodically and a
  /// final [IngestComplete]. Reconciliation (rows that disappeared)
  /// happens after the scan stream closes.
  ///
  /// The whole call is wrapped in a single sqflite transaction so a
  /// crash mid-scan leaves the cache in its pre-scan state — except
  /// vec0 inserts which commit per-statement (vec0 doesn't fully
  /// participate in nested savepoints; in practice this is
  /// acceptable because a partial-ingest re-run would re-upsert the
  /// same embedding bytes).
  Stream<IngestEvent> run(Stream<ScanEvent> scanEvents) async* {
    var summary = IngestSummary.empty;
    final seenPaths = <String>{};

    // Materialise the stream first — we want a single transactional
    // commit at the end. For a 5k-track library this peaks at ~1 MB
    // of scanner state which is fine; if it ever became a problem we
    // could batch into multiple transactions of N tracks each.
    final events = <ScanEvent>[];
    await for (final e in scanEvents) {
      events.add(e);
      if (e is ScanDiscovered) {
        // Cheap progress emission — UI doesn't need every event.
        if (events.length % 25 == 0) {
          yield IngestProgress(
            processed: events.length,
            totalSoFar: seenPaths.length,
          );
        }
      }
    }

    await cache.writer.transaction((txn) async {
      for (final event in events) {
        if (event is! ScanDiscovered) continue;
        final track = event.track;
        seenPaths.add(track.path);

        final sidecarFile = _siblingSidecarFile(track.path);
        final readResult = await _reader.read(sidecarFile);
        final addedAtMs = _now().millisecondsSinceEpoch;

        switch (readResult) {
          case SidecarReady(:final sidecar):
            final mtime = await _statMtimeMs(sidecarFile);
            final row = buildTrackRow(
              track: track,
              sidecar: sidecar,
              sidecarPath: sidecarFile.path,
              sidecarMtimeMs: mtime,
              status: TrackStatus.ready,
              addedAtMs: addedAtMs,
            );
            final id = await upsertTrackRow(txn, row: row);
            await upsertEmbedding(
              txn,
              trackId: id,
              embedding: embeddingBytes(sidecar.embedding),
            );
            summary = summary.copyWith(ready: summary.ready + 1);
          case SidecarStale():
            final row = buildTrackRow(
              track: track,
              sidecar: null,
              sidecarPath: sidecarFile.path,
              sidecarMtimeMs: null,
              status: TrackStatus.analysisPending,
              addedAtMs: addedAtMs,
            );
            final id = await upsertTrackRow(txn, row: row);
            // A previously-ready row that just went stale must lose
            // its embedding so mood/vibe/kNN stop returning it.
            await deleteEmbedding(txn, id);
            summary = summary.copyWith(
              analysisPending: summary.analysisPending + 1,
            );
          case SidecarMissing():
            final row = buildTrackRow(
              track: track,
              sidecar: null,
              sidecarPath: null,
              sidecarMtimeMs: null,
              status: TrackStatus.analysisPending,
              addedAtMs: addedAtMs,
            );
            final id = await upsertTrackRow(txn, row: row);
            await deleteEmbedding(txn, id);
            summary = summary.copyWith(
              analysisPending: summary.analysisPending + 1,
            );
        }
      }

      // Reconcile: rows whose `path` didn't appear in this scan flip
      // to `missing_audio`, with their embedding dropped. We do this
      // in a batch-update so the round-trip count is constant.
      if (seenPaths.isEmpty) {
        // Nothing scanned — flip every previously-`ready` row.
        final affected = await txn.update(
          'tracks',
          {'status': TrackStatus.missingAudio.value},
          where: "status != 'missing_audio'",
        );
        summary = summary.copyWith(missingAudio: affected);
      } else {
        // Two-step: select the IDs that need updating, then update +
        // delete embeddings in batches. We avoid `NOT IN (?, ?, ...)`
        // for the obvious O(N²) reason at 5k tracks.
        await txn.execute('''
          CREATE TEMPORARY TABLE _ingest_seen(path TEXT PRIMARY KEY)
        ''');
        final batch = txn.batch();
        for (final p in seenPaths) {
          batch.insert('_ingest_seen', {'path': p});
        }
        await batch.commit(noResult: true);

        final toMiss = await txn.rawQuery(
          '''
          SELECT id FROM tracks
           WHERE status != 'missing_audio'
             AND path NOT IN (SELECT path FROM _ingest_seen)
          ''',
        );
        if (toMiss.isNotEmpty) {
          final ids = toMiss.map((r) => r['id'] as int).toList();
          final placeholders = List.filled(ids.length, '?').join(',');
          await txn.execute(
            'UPDATE tracks SET status = ? WHERE id IN ($placeholders)',
            [TrackStatus.missingAudio.value, ...ids],
          );
          await txn.execute(
            'DELETE FROM track_embeddings WHERE track_id IN ($placeholders)',
            ids,
          );
          summary = summary.copyWith(missingAudio: ids.length);
        }
        await txn.execute('DROP TABLE _ingest_seen');
      }
    });

    yield IngestComplete(summary);
  }

  /// Resolves the sibling `<basename>.sonic.json` for [audioPath].
  /// Pure path math — no I/O.
  static File _siblingSidecarFile(String audioPath) {
    final dot = audioPath.lastIndexOf('.');
    final stem = dot <= 0 ? audioPath : audioPath.substring(0, dot);
    return File('$stem.sonic.json');
  }

  static Future<int?> _statMtimeMs(File f) async {
    try {
      final stat = await f.stat();
      return stat.modified.toUtc().millisecondsSinceEpoch;
    } on FileSystemException {
      return null;
    }
  }
}
