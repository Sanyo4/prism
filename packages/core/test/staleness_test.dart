import 'package:prism_core/core.dart';
import 'package:test/test.dart';

void main() {
  group('staleness matrix', () {
    const reader = SidecarReader();

    test('all four reasons map to distinct enum values', () {
      // Sanity check: enums kept stable for downstream consumers.
      expect(StalenessReason.values, hasLength(4));
      expect(
        {
          StalenessReason.schemaMismatch,
          StalenessReason.analyzerMismatch,
          StalenessReason.malformedJson,
          StalenessReason.conflictCopy,
        },
        StalenessReason.values.toSet(),
      );
    });

    test('schemaMismatch wins over analyzerMismatch', () {
      // Both bad: schema=2, analyzer={future-model}. Reader checks
      // schema first (cheaper) so it surfaces first.
      const json = '{"schema_version":2,"analyzer_models":["future-model"]}';
      final r = reader.parse(json) as SidecarStale;
      expect(r.reason, StalenessReason.schemaMismatch);
    });

    test('analyzerMismatch surfaces when schema is current but models drift',
        () {
      const json =
          '{"schema_version":1,"analyzer_models":["unknown-model-v999"]}';
      final r = reader.parse(json) as SidecarStale;
      expect(r.reason, StalenessReason.analyzerMismatch);
    });

    test('analyzer overlap with at least one compatible model passes the gate',
        () {
      // Even one compatible model is enough; the rest can be future
      // models slice 4 doesn't yet recognise.
      final json =
          '{"schema_version":1,"analyzer_models":["msd-musicnn-1","exotic-future-head-3"],'
          '"analyzer":"x","audio_sha1":"${'a' * 40}","duration_sec":1,"sample_rate":44100,'
          '"bit_depth":16,"bpm":120,"bpm_confidence":0.5,"key":"C","key_confidence":0.5,'
          '"loudness_lufs":-14,"replaygain_track_db":-6,"replaygain_album_db":-6,'
          '"spectral_centroid_mean":1000,"danceability":0.5,'
          '"mood":{"happy":0.1,"sad":0.1,"aggressive":0.1,"relaxed":0.1,"party":0.1},'
          '"genre_top3":[["a",0.1],["b",0.1],["c",0.1]],"voice_instrumental":0.1,'
          '"embedding_model":"discogs-effnet-bs64-1","embedding":[${List.filled(1280, "0.0").join(",")}]}';
      final result = reader.parse(json);
      expect(result, isA<SidecarReady>(),
          reason: 'partial overlap should still pass the analyzer gate');
    });
  });
}
