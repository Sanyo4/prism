import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/backfill/backfill_queue.dart';
import 'package:mobile/backfill/track_patch.dart';
import 'package:prism_core/core.dart';
import 'package:prism_metadata/metadata.dart';

void main() {
  group('BackfillQueue', () {
    test('100 tracks, 40 missing → 40 patches emitted (mid-pause observed)',
        () async {
      final tracks = List.generate(100, (i) {
        final missing = i < 40; // first 40 are tagless
        return Track(
          path: '/m/$i.flac',
          mtimeMs: 0,
          title: 'Title $i',
          artist: missing ? null : 'Artist',
          album: missing ? null : 'Album',
          year: missing ? null : 2000,
        );
      });

      final repo = _FakeRepo(
        configured: true,
        // For each missing track, emit a populated patch; fully-tagged
        // tracks never reach the repo so we don't need to handle them.
        backfillImpl: (t) async {
          // Pause briefly so the test can observe in-flight state.
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return TrackMetadataPatch(
            artist: 'Artist',
            album: 'Album',
            year: 2000,
            recordingMbid: 'rec-${t.path}',
            releaseMbid: 'rel-${t.path}',
            artistMbid: 'art-${t.path}',
            coverUrl: 'https://caa/${t.path}',
          );
        },
      );

      final q = BackfillQueue(repo: repo);
      addTearDown(q.dispose);
      final patches = <TrackPatch>[];
      final sub = q.stream.listen(patches.add);
      addTearDown(sub.cancel);

      final run = q.run(tracks);
      // While it's running, observe in-flight state.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(q.isRunning, isTrue);
      await run;
      // Broadcast-stream listeners receive events on the microtask
      // queue; after `run` resolves the controller's `add()` calls
      // have happened but listener invocations are still pending.
      // Pumping flushes them so the assertion sees the full count.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(patches, hasLength(40));
      expect(patches.first.path, '/m/0.flac');
      expect(patches.last.path, '/m/39.flac');
      // Repo only saw the 40 tagless tracks — fully-tagged ones were
      // skipped before entering the repo.
      expect(repo.calls, 40);
    });

    test('flipping configured to false mid-run aborts the loop', () async {
      final tracks = List.generate(20, (i) {
        return Track(path: '/m/$i.flac', mtimeMs: 0, title: 'T$i');
      });
      var configured = true;
      final repo = _FakeRepo(
        configuredFn: () => configured,
        backfillImpl: (t) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return const TrackMetadataPatch(artist: 'A', album: 'B', year: 1999);
        },
      );

      final q = BackfillQueue(repo: repo);
      addTearDown(q.dispose);

      // Flip the config off after a few ms; the loop should exit on
      // the next iteration.
      Timer(const Duration(milliseconds: 5), () => configured = false);
      await q.run(tracks);

      expect(repo.calls, lessThan(20),
          reason: 'config flip should abort before full pass');
    });

    test('repository exception is swallowed; loop continues', () async {
      final tracks = List.generate(5, (i) {
        return Track(path: '/m/$i.flac', mtimeMs: 0, title: 'T$i');
      });
      var calls = 0;
      final repo = _FakeRepo(
        configured: true,
        backfillImpl: (t) async {
          calls++;
          if (calls == 2) throw Exception('upstream blew up');
          return const TrackMetadataPatch(artist: 'A', album: 'B', year: 2000);
        },
      );

      final q = BackfillQueue(repo: repo);
      addTearDown(q.dispose);
      final patches = <TrackPatch>[];
      final sub = q.stream.listen(patches.add);
      addTearDown(sub.cancel);

      await q.run(tracks);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 5 tracks total; 1 threw, so 4 emit a patch.
      expect(patches, hasLength(4));
    });

    test('TrackMetadataPatch.empty does not produce an event', () async {
      final tracks = [Track(path: '/m/empty.flac', mtimeMs: 0, title: 'T')];
      final repo = _FakeRepo(
        configured: true,
        backfillImpl: (_) async => TrackMetadataPatch.empty,
      );

      final q = BackfillQueue(repo: repo);
      addTearDown(q.dispose);
      final patches = <TrackPatch>[];
      final sub = q.stream.listen(patches.add);
      addTearDown(sub.cancel);
      await q.run(tracks);
      expect(patches, isEmpty);
    });

    test('unconfigured repo: no backfill calls at all', () async {
      final tracks = [Track(path: '/m/x.flac', mtimeMs: 0, title: 'T')];
      final repo = _FakeRepo(configured: false, backfillImpl: (_) async {
        fail('repo should never be called when unconfigured');
      });
      final q = BackfillQueue(repo: repo);
      addTearDown(q.dispose);
      await q.run(tracks);
      expect(repo.calls, 0);
    });
  });
}

class _FakeRepo implements MetadataRepository {
  _FakeRepo({
    bool configured = false,
    bool Function()? configuredFn,
    required this.backfillImpl,
  })  : _configured = configured,
        _configuredFn = configuredFn;

  final bool _configured;
  final bool Function()? _configuredFn;
  final Future<TrackMetadataPatch> Function(Track) backfillImpl;
  int calls = 0;

  @override
  bool get configured => _configuredFn?.call() ?? _configured;

  @override
  Future<TrackMetadataPatch> backfill(Track t) async {
    calls++;
    return backfillImpl(t);
  }

  @override
  Future<void> clearCache() async {}

  @override
  Future<LastfmArtistInfo?> artistInfo(String mbid) async => null;

  @override
  Future<String?> coverArtUrl(String releaseMbid) async => null;
}
