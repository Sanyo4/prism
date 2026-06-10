import 'dart:io';

import 'package:prism_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('SidecarReader', () {
    const reader = SidecarReader();

    test('reads a real slice-3 sidecar from the indexer fixtures', () async {
      final fixture = File(
        'apps/indexer/tests/fixtures/library/silence_0.sonic.json',
      );
      // Tests run from the workspace root in `dart test` invocations.
      // If the path resolution shifts (e.g. CI runs from packages/core),
      // walk one level up.
      final file = fixture.existsSync()
          ? fixture
          : File('../../${fixture.path}');
      expect(file.existsSync(), isTrue,
          reason: 'fixture sidecar should exist at $fixture or ../../$fixture');
      final result = await reader.read(file);
      expect(result, isA<SidecarReady>());
      final sidecar = (result as SidecarReady).sidecar;
      expect(sidecar.schemaVersion, kCurrentSidecarSchemaVersion);
      expect(sidecar.embedding, hasLength(1280));
      expect(sidecar.genreTop3, hasLength(3));
      expect(sidecar.analyzerModels, contains('msd-musicnn-1'));
      expect(sidecar.audioSha1, hasLength(40));
      expect(sidecar.mood.happy, inInclusiveRange(0.0, 1.0));
    });

    test('SidecarMissing for absent file', () async {
      final result = await reader.read(File('/tmp/definitely-not-here.json'));
      expect(result, isA<SidecarMissing>());
    });

    test('SidecarStale.malformedJson for unparseable JSON', () async {
      final result = reader.parse('this is not json');
      expect(result, isA<SidecarStale>());
      expect((result as SidecarStale).reason, StalenessReason.malformedJson);
    });

    test('SidecarStale.malformedJson when top-level is not an object',
        () async {
      final result = reader.parse('[1, 2, 3]');
      expect(result, isA<SidecarStale>());
      expect((result as SidecarStale).reason, StalenessReason.malformedJson);
    });

    test('SidecarStale.schemaMismatch when schema_version != current',
        () async {
      final synthetic = _syntheticJson(schemaVersion: 999);
      final result = reader.parse(synthetic);
      expect(result, isA<SidecarStale>());
      expect((result as SidecarStale).reason, StalenessReason.schemaMismatch);
    });

    test(
        'SidecarStale.analyzerMismatch when analyzer_models has no overlap',
        () async {
      final synthetic = _syntheticJson(
        schemaVersion: 1,
        analyzerModels: const ['some-future-model-2.0'],
      );
      final result = reader.parse(synthetic);
      expect(result, isA<SidecarStale>());
      expect((result as SidecarStale).reason, StalenessReason.analyzerMismatch);
    });

    test('SidecarStale.conflictCopy when filename has .sync-conflict-',
        () async {
      // We only need a path-level test; reader checks the basename
      // before any I/O. Use a non-existent path.
      final f = File('/tmp/01 - Track.sync-conflict-20260401-ABC.sonic.json');
      final result = await reader.read(f);
      expect(result, isA<SidecarStale>());
      expect((result as SidecarStale).reason, StalenessReason.conflictCopy);
    });

    test('forward-compat: tolerates unknown JSON keys', () async {
      final synthetic =
          _syntheticJson(schemaVersion: 1, extraKeys: {'future_field': 42});
      final result = reader.parse(synthetic);
      expect(result, isA<SidecarReady>(),
          reason: 'unknown keys must not break the parser '
              '(spec versioning rule)');
    });
  });
}

String _syntheticJson({
  required int schemaVersion,
  List<String>? analyzerModels,
  Map<String, Object?>? extraKeys,
}) {
  final base = <String, Object?>{
    'schema_version': schemaVersion,
    'analyzer': 'essentia-2.1-beta6-dev',
    'analyzer_models':
        analyzerModels ?? ['msd-musicnn-1', 'discogs-effnet-bs64-1'],
    'audio_sha1': 'a' * 40,
    'duration_sec': 30.0,
    'sample_rate': 44100,
    'bit_depth': 16,
    'bpm': 120.0,
    'bpm_confidence': 0.9,
    'key': 'C',
    'key_confidence': 0.6,
    'loudness_lufs': -14.0,
    'replaygain_track_db': -6.0,
    'replaygain_album_db': -6.0,
    'spectral_centroid_mean': 1500.0,
    'danceability': 0.5,
    'mood': {
      'happy': 0.5,
      'sad': 0.2,
      'aggressive': 0.1,
      'relaxed': 0.6,
      'party': 0.3,
    },
    'genre_top3': [
      ['rock', 0.4],
      ['pop', 0.3],
      ['indie', 0.2],
    ],
    'voice_instrumental': 0.1,
    'embedding_model': 'discogs-effnet-bs64-1',
    'embedding': List<double>.generate(1280, (i) => 0.0),
  };
  if (extraKeys != null) base.addAll(extraKeys);
  return _jsonEncode(base);
}

String _jsonEncode(Object value) {
  // Hand-rolled JSON encoder via dart:convert pulled in by the parse
  // path; re-using package:test would be silly.
  return _encode(value);
}

String _encode(Object? v) {
  if (v == null) return 'null';
  if (v is num) return v.toString();
  if (v is String) {
    // Cheap escaping — fixtures don't include special chars.
    return '"${v.replaceAll('"', r'\"')}"';
  }
  if (v is List) {
    return '[${v.map(_encode).join(',')}]';
  }
  if (v is Map) {
    return '{${v.entries.map((e) => '"${e.key}":${_encode(e.value)}').join(',')}}';
  }
  return '"${v.toString()}"';
}
