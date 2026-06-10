import 'dart:convert';
import 'dart:io';

import 'package:prism_core/core.dart';
import 'package:test/test.dart';

import '_test_helpers.dart';

void main() {
  group('IngestCoordinator', () {
    test(
        'ingests a fixture tree with paired sidecars + an orphan + a sync-conflict',
        () async {
      final tree = _buildFixtureTree();
      addTearDown(() => tree.dir.deleteSync(recursive: true));

      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);

      final coordinator = IngestCoordinator(cache: ctx.db);
      final scanner = LibraryScanner();
      final token = CancellationToken();
      // Note: we drive scanner against a synthetic tree of empty
      // files. `audio_metadata_reader` will fail to parse 0-byte
      // files, so we instead synthesise the ScanEvent stream
      // directly to avoid that dependency. This test is about ingest,
      // not scanner.
      final events = Stream<ScanEvent>.fromIterable([
        for (final t in tree.tracks)
          ScanDiscovered(_syntheticTrack(t.path)),
        const ScanDone(cancelled: false, count: 0),
      ]);
      // ignore: unused_local_variable
      final scannerRef = scanner;
      // ignore: unused_local_variable
      final tokenRef = token;

      final outcomes = <IngestEvent>[];
      await for (final e in coordinator.run(events)) {
        outcomes.add(e);
      }
      expect(outcomes.last, isA<IngestComplete>());
      final summary = (outcomes.last as IngestComplete).summary;
      expect(summary.ready, tree.expectedReady,
          reason: 'paired audio + valid sidecars should land as ready');
      expect(summary.analysisPending, tree.expectedPending,
          reason:
              'audio without sidecar OR with conflict-copy sibling should be pending');
      expect(summary.missingAudio, 0,
          reason: 'first run has nothing to reconcile');
      expect(summary.errors, 0);

      // Orphan sidecar must NOT have produced a row — there's no audio
      // file at its non-.sonic.json sibling, so scanner never yields it.
      final orphanRow = await ctx.db.writer.query(
        'tracks',
        where: 'path = ?',
        whereArgs: [tree.orphanSidecarStub],
        limit: 1,
      );
      expect(orphanRow, isEmpty);

      // Embedding count matches `ready`.
      final embedRows = ctx.db.reader
          .select('SELECT COUNT(*) AS n FROM track_embeddings');
      expect(embedRows.first['n'], summary.ready);
    });

    test(
        'sidecar deletion + re-scan flips ready→analysis_pending and drops embedding',
        () async {
      final tree = _buildFixtureTree();
      addTearDown(() => tree.dir.deleteSync(recursive: true));
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final coordinator = IngestCoordinator(cache: ctx.db);
      // First run.
      await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();
      final initialReady = (await ctx.db.writer.rawQuery(
        "SELECT COUNT(*) AS n FROM tracks WHERE status = 'ready'",
      ))
          .first['n'] as int;
      expect(initialReady, tree.expectedReady);

      // Delete one valid sidecar so the next ingest sees it as
      // SidecarMissing for an audio that's still present.
      final victim = tree.tracks.firstWhere(
        (t) => t.kind == _Kind.paired,
      );
      File(_siblingSidecarPath(victim.path)).deleteSync();

      // Second run.
      final outcomes2 = await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();
      final summary2 = (outcomes2.last as IngestComplete).summary;
      expect(summary2.ready, tree.expectedReady - 1);
      expect(summary2.analysisPending, tree.expectedPending + 1);

      // The victim row exists, status flipped, embedding dropped.
      final row = (await ctx.db.writer.query(
        'tracks',
        where: 'path = ?',
        whereArgs: [victim.path],
      ))
          .single;
      expect(row['status'], 'analysis_pending');
      final embedRows = ctx.db.reader.select(
        'SELECT track_id FROM track_embeddings WHERE track_id = ?',
        [row['id']],
      );
      expect(embedRows, isEmpty,
          reason:
              'embedding for a regressed-to-pending track must be deleted');
    });

    test(
        'sidecars from a future schema version are treated as analysis_pending',
        () async {
      // Mirrors §11 item 8 of the slice plan: a schema_version bump
      // (or in the inverse case, sidecars from a *prior* slice with a
      // bumped current) flips every row to analysis_pending without
      // orphaning embeddings.
      final tree = _buildFixtureTree();
      addTearDown(() => tree.dir.deleteSync(recursive: true));
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final coordinator = IngestCoordinator(cache: ctx.db);

      // First run with valid (schema=1) sidecars — every paired track
      // lands ready.
      await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();

      // Now rewrite every paired sidecar to schema_version=2 — slice
      // 4 only understands v1.
      for (final t in tree.tracks) {
        if (t.kind != _Kind.paired) continue;
        final sidecarPath = _siblingSidecarPath(t.path);
        final orig = json.decode(File(sidecarPath).readAsStringSync())
            as Map<String, dynamic>;
        orig['schema_version'] = 2;
        File(sidecarPath).writeAsStringSync(json.encode(orig));
      }

      final outcomes = await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();
      final summary = (outcomes.last as IngestComplete).summary;
      expect(summary.ready, 0,
          reason: 'every row should fail the schema gate');
      expect(summary.analysisPending, tree.tracks.length);
      // No orphan embeddings — every row that lost ready status had
      // its embedding dropped.
      final orphanEmbed = ctx.db.reader.select('''
        SELECT COUNT(*) AS n
          FROM track_embeddings
         WHERE track_id NOT IN (SELECT id FROM tracks WHERE status = 'ready')
      ''');
      expect(orphanEmbed.first['n'], 0);
    });

    test(
        'reconcile flips rows whose path was not seen this scan to missing_audio',
        () async {
      final tree = _buildFixtureTree();
      addTearDown(() => tree.dir.deleteSync(recursive: true));
      final ctx = await openFreshTestDb();
      addTearDown(ctx.teardown);
      final coordinator = IngestCoordinator(cache: ctx.db);
      // First run sees both files.
      await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();
      final pairedTrack =
          tree.tracks.firstWhere((t) => t.kind == _Kind.paired);
      // Second run drops the paired track from the scan stream.
      final outcomes = await coordinator
          .run(Stream<ScanEvent>.fromIterable([
            for (final t in tree.tracks)
              if (t.path != pairedTrack.path) ScanDiscovered(_syntheticTrack(t.path)),
            const ScanDone(cancelled: false, count: 0),
          ]))
          .toList();
      final summary = (outcomes.last as IngestComplete).summary;
      expect(summary.missingAudio, 1);
      final row = (await ctx.db.writer.query(
        'tracks',
        where: 'path = ?',
        whereArgs: [pairedTrack.path],
      ))
          .single;
      expect(row['status'], 'missing_audio');
    });
  });
}

class _FixtureTree {
  final Directory dir;
  final List<_FixtureTrack> tracks;
  final String orphanSidecarStub;
  int get expectedReady =>
      tracks.where((t) => t.kind == _Kind.paired).length;
  int get expectedPending =>
      tracks.where((t) => t.kind != _Kind.paired).length;
  _FixtureTree({
    required this.dir,
    required this.tracks,
    required this.orphanSidecarStub,
  });
}

enum _Kind {
  /// Audio + valid sidecar present.
  paired,

  /// Audio present, no sidecar at all.
  missingSidecar,

  /// Audio present, sibling is a sync-conflict copy.
  conflictCopy,
}

class _FixtureTrack {
  final String path;
  final _Kind kind;
  _FixtureTrack(this.path, this.kind);
}

/// Builds a temp directory structured like a Syncthing folder. Stubs
/// audio files as zero-byte placeholders — ingest only needs the path
/// to exist for the sidecar-pair lookup.
_FixtureTree _buildFixtureTree() {
  final dir = Directory.systemTemp.createTempSync('prism-ingest-fixture-');
  final tracks = <_FixtureTrack>[];
  // 5 valid pairs.
  for (var i = 0; i < 5; i++) {
    final base = '${dir.path}/album/track-$i';
    File('$base.flac').createSync(recursive: true);
    File('$base.sonic.json').writeAsStringSync(_validSidecarJson(seed: i));
    tracks.add(_FixtureTrack('$base.flac', _Kind.paired));
  }
  // 1 audio without a sidecar.
  final missing = '${dir.path}/album/track-missing.flac';
  File(missing).createSync();
  tracks.add(_FixtureTrack(missing, _Kind.missingSidecar));

  // 1 audio whose sibling is a sync-conflict copy.
  final conflict = '${dir.path}/album/track-conflict.flac';
  File(conflict).createSync();
  File('${dir.path}/album/track-conflict.sync-conflict-20260401-ABC.sonic.json')
      .writeAsStringSync(_validSidecarJson(seed: 99));
  tracks.add(_FixtureTrack(conflict, _Kind.conflictCopy));

  // 1 orphan sidecar — no matching audio. Tracked only for assertion;
  // the scanner stream omits it.
  final orphanStub = '${dir.path}/album/track-orphan.flac';
  File('${dir.path}/album/track-orphan.sonic.json')
      .writeAsStringSync(_validSidecarJson(seed: 7));
  return _FixtureTree(
      dir: dir, tracks: tracks, orphanSidecarStub: orphanStub);
}

String _siblingSidecarPath(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  final stem = dot <= 0 ? audioPath : audioPath.substring(0, dot);
  return '$stem.sonic.json';
}

Track _syntheticTrack(String path) =>
    Track(path: path, mtimeMs: 0, title: null, artist: null);

String _validSidecarJson({required int seed}) {
  final embedding = List<double>.generate(1280, (i) => ((seed + i) % 1280) / 1280.0);
  final body = {
    'schema_version': 1,
    'analyzer': 'essentia-2.1-beta6-dev',
    'analyzer_models': ['msd-musicnn-1', 'discogs-effnet-bs64-1'],
    'audio_sha1': (seed.toRadixString(16) * 40).substring(0, 40),
    'duration_sec': 30.0 + seed,
    'sample_rate': 44100,
    'bit_depth': 16,
    'bpm': 90.0 + seed * 5,
    'bpm_confidence': 0.8,
    'key': 'Am',
    'key_confidence': 0.5,
    'loudness_lufs': -14.0,
    'replaygain_track_db': -6.0,
    'replaygain_album_db': -6.0,
    'spectral_centroid_mean': 1500.0 + seed * 10,
    'danceability': 0.5,
    'mood': {
      'happy': 0.1 + 0.05 * (seed % 5),
      'sad': 0.6 - 0.05 * (seed % 5),
      'aggressive': 0.05,
      'relaxed': 0.5,
      'party': 0.2,
    },
    'genre_top3': [
      ['rock', 0.4],
      ['pop', 0.3],
      ['indie', 0.2],
    ],
    'voice_instrumental': 0.5,
    'embedding_model': 'discogs-effnet-bs64-1',
    'embedding': embedding,
  };
  return json.encode(body);
}
