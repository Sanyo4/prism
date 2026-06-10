import 'dart:math' as math;
import 'dart:typed_data';

import 'package:prism_playlist_engine/playlist_engine.dart';

/// In-memory PlaylistRepo for engine tests. Zero Flutter / SQLite —
/// proves the engine API stays platform-agnostic. Distance is
/// brute-force L2 in pure Dart.
class FakeRepo implements PlaylistRepo {
  final Map<int, Float32List> embeddings = {};
  final Map<int, CandidateMeta> metas = {};
  final Map<String, List<int>> albumTracks = {};
  final Map<String, List<int>> artistTracks = {};

  /// Default seeded RNG so tests are deterministic.
  math.Random rng = math.Random(0);

  /// Add a synthetic track. Embedding is a 1280-dim vector with the
  /// first 8 dims set to [embeddingSeed], then descending zeroes —
  /// enough to give the kNN sweep meaningful ordering.
  void addTrack({
    required int id,
    required String artist,
    required String title,
    String key = '',
    int? year,
    double bpm = 110.0,
    double moodHappy = 0.0,
    double moodSad = 0.0,
    double moodRelaxed = 0.0,
    double moodAggressive = 0.0,
    double moodParty = 0.0,
    double danceability = 0.0,
    double voiceInstrumental = 0.0,
    String? album,
    Float32List? embedding,
  }) {
    final emb = embedding ?? _syntheticEmbedding(id);
    if (emb.length != 1280) {
      throw ArgumentError('embedding must be length 1280, got ${emb.length}');
    }
    embeddings[id] = emb;
    final artistKey = artist.toLowerCase().trim();
    metas[id] = CandidateMeta(
      trackId: id,
      artistKey: artistKey,
      title: title,
      key: key,
      year: year,
      bpm: bpm,
      moodHappy: moodHappy,
      moodSad: moodSad,
      moodRelaxed: moodRelaxed,
      moodAggressive: moodAggressive,
      moodParty: moodParty,
      danceability: danceability,
      voiceInstrumental: voiceInstrumental,
    );
    artistTracks.putIfAbsent(artistKey, () => []).add(id);
    if (album != null) {
      albumTracks.putIfAbsent(album, () => []).add(id);
    }
  }

  static Float32List _syntheticEmbedding(int seed) {
    final out = Float32List(1280);
    for (var i = 0; i < 1280; i++) {
      out[i] = ((seed + i) % 1280) / 1280.0;
    }
    return out;
  }

  @override
  Future<Float32List> embeddingOf(int trackId) async {
    final e = embeddings[trackId];
    if (e == null) throw StateError('no embedding for $trackId');
    if (e.length != 1280) {
      throw ArgumentError('expected 1280, got ${e.length}');
    }
    return Float32List.fromList(e);
  }

  @override
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey) async =>
      _meanOfIds(albumTracks[albumKey] ?? const []);

  @override
  Future<Float32List?> meanEmbeddingForArtist(String artist) async =>
      _meanOfIds(artistTracks[artist.toLowerCase().trim()] ?? const []);

  Float32List? _meanOfIds(List<int> ids) {
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

  @override
  Future<List<KnnHit>> knnByEmbedding(
    Float32List seed, {
    int k = 200,
  }) async {
    final ranked = <KnnHit>[];
    for (final entry in embeddings.entries) {
      final id = entry.key;
      final v = entry.value;
      var sum = 0.0;
      for (var i = 0; i < 1280; i++) {
        final d = v[i] - seed[i];
        sum += d * d;
      }
      ranked.add(KnnHit(trackId: id, l2Distance: math.sqrt(sum)));
    }
    ranked.sort((a, b) => a.l2Distance.compareTo(b.l2Distance));
    if (ranked.length > k) return ranked.sublist(0, k);
    return ranked;
  }

  @override
  Future<CandidateMeta> metaOf(int trackId) async {
    final m = metas[trackId];
    if (m == null) throw StateError('no meta for $trackId');
    return m;
  }

  @override
  Future<List<CandidateMeta>> metaOfMany(Iterable<int> ids) async {
    final out = <CandidateMeta>[];
    for (final id in ids) {
      final m = metas[id];
      if (m != null) out.add(m);
    }
    return out;
  }

  @override
  Future<List<int>> libraryWideFallback({int limit = 100}) async {
    final all = embeddings.keys.toList()..shuffle(rng);
    if (all.length > limit) return all.sublist(0, limit);
    return all;
  }
}
