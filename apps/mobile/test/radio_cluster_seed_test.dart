import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/radio_providers.dart';
import 'package:prism_core/core.dart' hide KnnHit;
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WidgetsFlutterBinding.ensureInitialized();
  });

  test('buildClusterSession averages resolvable embeddings into a ClusterSeed',
      () async {
    final repo = _StubRepo();
    repo.addTrackWithEmbedding(1, _embedAt(0, 1.0));
    repo.addTrackWithEmbedding(2, _embedAt(1, 1.0));

    final container = ProviderContainer(
      overrides: [
        playlistRepoProvider.overrideWith((ref) async => repo),
        pathToIdProvider.overrideWith((ref) async => const {
              '/a.flac': 1,
              '/b.flac': 2,
            }),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(radioSessionProvider.notifier);
    final session = await notifier.buildClusterSession(
      const [
        Track(path: '/a.flac', mtimeMs: 0, title: 'A'),
        Track(path: '/b.flac', mtimeMs: 0, title: 'B'),
      ],
      steeringHint: 'rainy_sunday',
    );
    expect(session, isNotNull);
    final seed = session!.seed;
    expect(seed, isA<ClusterSeed>());
    final cluster = seed as ClusterSeed;
    expect(cluster.steeringHint, 'rainy_sunday');
    expect(cluster.trackIds, equals(<int>[1, 2]));
    expect(cluster.label, 'rainy_sunday');
    // Seed embedding is L2-normalised — squared magnitude ≈ 1.0.
    var sumSq = 0.0;
    for (final v in session.seedEmbedding) {
      sumSq += v * v;
    }
    expect(sumSq, closeTo(1.0, 1e-3));
  });

  test('buildClusterSession returns null on zero resolvable tracks',
      () async {
    final repo = _StubRepo();
    final container = ProviderContainer(
      overrides: [
        playlistRepoProvider.overrideWith((ref) async => repo),
        pathToIdProvider.overrideWith((ref) async => const <String, int>{}),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(radioSessionProvider.notifier);
    final session = await notifier.buildClusterSession(
      const [Track(path: '/missing.flac', mtimeMs: 0)],
    );
    expect(session, isNull);
  });

  test('buildClusterSession skips tracks whose embedding lookup throws',
      () async {
    final repo = _StubRepo();
    repo.addTrackWithEmbedding(1, _embedAt(0, 1.0));
    // id=2 has no embedding registered — embeddingOf throws StateError.

    final container = ProviderContainer(
      overrides: [
        playlistRepoProvider.overrideWith((ref) async => repo),
        pathToIdProvider.overrideWith((ref) async => const {
              '/a.flac': 1,
              '/b.flac': 2,
            }),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(radioSessionProvider.notifier);
    final session = await notifier.buildClusterSession(const [
      Track(path: '/a.flac', mtimeMs: 0),
      Track(path: '/b.flac', mtimeMs: 0),
    ]);
    expect(session, isNotNull);
    final cluster = session!.seed as ClusterSeed;
    expect(cluster.trackIds, equals(<int>[1]));
  });

  test('startFromCluster with empty list is a no-op', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(radioSessionProvider.notifier)
        .startFromCluster(const <Track>[]);
    expect(container.read(radioSessionProvider), isNull);
  });
}

Float32List _embedAt(int dim, double value) {
  final v = Float32List(1280);
  v[dim] = value;
  return v;
}

class _StubRepo implements PlaylistRepo {
  final Map<int, Float32List> _emb = {};

  void addTrackWithEmbedding(int id, Float32List e) {
    _emb[id] = e;
  }

  @override
  Future<Float32List> embeddingOf(int trackId) async {
    final e = _emb[trackId];
    if (e == null) throw StateError('no embedding for $trackId');
    return Float32List.fromList(e);
  }

  // Other methods unused by buildClusterSession's resolution path.
  @override
  Future<List<KnnHit>> knnByEmbedding(Float32List seed, {int k = 200}) async =>
      <KnnHit>[];
  @override
  Future<CandidateMeta> metaOf(int trackId) async =>
      throw UnimplementedError();
  @override
  Future<List<int>> libraryWideFallback({int limit = 100}) async => const [];
  @override
  Future<Float32List?> meanEmbeddingForAlbum(String albumKey) async => null;
  @override
  Future<Float32List?> meanEmbeddingForArtist(String artist) async => null;
  @override
  Future<List<CandidateMeta>> metaOfMany(Iterable<int> ids) async =>
      const <CandidateMeta>[];
}
