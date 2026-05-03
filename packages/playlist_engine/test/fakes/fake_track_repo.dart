import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart';

import 'fake_repo.dart';

/// In-memory [TrackRepo] for slice-6 engine tests. Extends slice-5's
/// `FakeRepo` (so `embeddingOf`, `metaOfMany`, `libraryWideFallback`
/// keep working) and layers on the slice-6 SQL-shape methods
/// (`candidatePoolByIntent`, `meanEmbeddingForKeywords`).
///
/// Pool semantics mirror the SQL filter shape from slice plan §8
/// step 6:
///   - `strict`: BPM range, era range, every mood `min` / `max`
///     constraint applies; ORDER BY primary mood DESC.
///   - `loose`: widen BPM ±10, drop era; primary mood only is
///     kept on `intent.copyRelaxed`.
///   - `veryLoose`: handled at the engine layer (it passes a
///     mutated intent); this fake honours whatever bounds it sees.
class FakeTrackRepo extends FakeRepo implements TrackRepo {
  /// Optional override the engine test can set to short-circuit
  /// `meanEmbeddingForKeywords` to a known target — useful for
  /// asserting that the cosine ranking favours the right pole.
  Float32List? keywordCentroidOverride;

  @override
  Future<List<int>> candidatePoolByIntent(
    Intent intent, {
    int poolSize = 200,
    RelaxationLevel relax = RelaxationLevel.strict,
  }) async {
    final out = <_Scored>[];
    final primaryMood = intent.moodTargets.isEmpty
        ? null
        : intent.moodTargets.first.mood;
    for (final entry in metas.entries) {
      final id = entry.key;
      final m = entry.value;
      // BPM clause.
      if (intent.bpmRange != null) {
        if (m.bpm < intent.bpmRange!.$1 || m.bpm > intent.bpmRange!.$2) {
          continue;
        }
      }
      // Era clause.
      if (intent.era != null) {
        if (m.year == null) continue;
        if (m.year! < intent.era!.$1 || m.year! > intent.era!.$2) {
          continue;
        }
      }
      // Mood clauses.
      var moodOk = true;
      for (final mt in intent.moodTargets) {
        final v = _moodScalar(m, mt.mood);
        if (mt.min != null && v < mt.min!) {
          moodOk = false;
          break;
        }
        if (mt.max != null && v > mt.max!) {
          moodOk = false;
          break;
        }
      }
      if (!moodOk) continue;
      out.add(_Scored(id, primaryMood == null ? 0.0 : _moodScalar(m, primaryMood)));
    }
    out.sort((a, b) => b.score.compareTo(a.score));
    final ids = [for (final s in out) s.id];
    if (ids.length <= poolSize) return ids;
    return ids.sublist(0, poolSize);
  }

  @override
  Future<Float32List> meanEmbeddingForKeywords(List<String> keywords) async {
    if (keywordCentroidOverride != null) {
      return keywordCentroidOverride!;
    }
    if (keywords.isEmpty) {
      return _meanOfAll();
    }
    // Snap each keyword via MoodLookup, then take the mean of all
    // tracks scoring high on those moods.
    final wantMoods = <String>{
      for (final kw in keywords) MoodLookup.snap(kw),
    };
    final ids = <int>[];
    for (final entry in metas.entries) {
      final m = entry.value;
      for (final mood in wantMoods) {
        if (_moodScalar(m, mood) >= 0.5) {
          ids.add(entry.key);
          break;
        }
      }
    }
    final mean = _meanFor(ids);
    if (mean != null) return mean;
    return _meanOfAll();
  }

  Float32List _meanOfAll() {
    final ids = embeddings.keys.toList();
    return _meanFor(ids) ?? Float32List(1280);
  }

  Float32List? _meanFor(List<int> ids) {
    if (ids.isEmpty) return null;
    final acc = Float32List(1280);
    var n = 0;
    for (final id in ids) {
      final e = embeddings[id];
      if (e == null) continue;
      for (var i = 0; i < 1280; i++) {
        acc[i] += e[i];
      }
      n++;
    }
    if (n == 0) return null;
    var sumSq = 0.0;
    for (var i = 0; i < 1280; i++) {
      acc[i] /= n;
      sumSq += acc[i] * acc[i];
    }
    final norm = math.sqrt(sumSq);
    if (norm == 0) return acc;
    final out = Float32List(1280);
    for (var i = 0; i < 1280; i++) {
      out[i] = acc[i] / norm;
    }
    return out;
  }

  static double _moodScalar(CandidateMeta m, String mood) {
    switch (mood) {
      case 'happy':
        return m.moodHappy;
      case 'sad':
        return m.moodSad;
      case 'aggressive':
        return m.moodAggressive;
      case 'relaxed':
        return m.moodRelaxed;
      case 'party':
        return m.moodParty;
      default:
        return 0.0;
    }
  }
}

class _Scored {
  final int id;
  final double score;
  const _Scored(this.id, this.score);
}
