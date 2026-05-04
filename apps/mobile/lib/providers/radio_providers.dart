/// Riverpod wiring for slice 5's Infinite Radio.
///
/// Public surface:
///
/// - [radioSessionProvider] — `NotifierProvider<RadioSessionNotifier,
///   RadioSession?>`. Null when off; the notifier exposes
///   `startFromTrack`, `startFromAlbum`, `startFromArtist`,
///   `toggleChip`, and `stop`.
/// - [radioModeProvider] — derived bool, true iff
///   `radioSessionProvider` is non-null. UI consumers (the badge,
///   chip bar, queue header, home card) gate visibility on this.
/// - [lookaheadManagerProvider] — owned by [radioSessionProvider]'s
///   notifier so the manager's lifetime tracks session lifetime.
/// - [recentSeedsStoreProvider] / [recentSeedsProvider] — persistent
///   LRU of three seeds — slice-10 retired the `RadioHomeCard` surface;
///   the store stays for slice-5 long-press re-entry semantics.
/// - [playlistRepoProvider] — wraps `CacheDb` in Track A's
///   `PlaylistRepoImpl` (defined in `package:prism_core/core.dart`).
///   Async because `cacheDbProvider` is a `FutureProvider`.
///
/// Engine usage flow (paraphrased from §5):
///   1. UI calls `radioSessionProvider.notifier.startFromTrack(track)`.
///   2. Notifier resolves `playlistRepoProvider`, calls
///      `RadioEngine.fromTrack`, gets a fresh `RadioSession`.
///   3. Notifier publishes the session, hands it to `LookaheadManager`,
///      which primes the queue with 5 picks via
///      [QueueService.appendForRadio].
///   4. Per advance, `LookaheadManager` pops + calls `engine.next` +
///      appends one more.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
// `prism_core` and `prism_playlist_engine` both export a `KnnHit` —
// the engine's is the one we use here; hide the core symbol so we
// don't ambiguous-import it.
import 'package:prism_core/core.dart' hide KnnHit;
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../radio/lookahead_manager.dart';
import '../radio/recent_seeds_store.dart';
import 'cache_db_providers.dart';
import 'metadata_providers.dart';
import 'playback_providers.dart';

// ---------------------------------------------------------------------------
// PlaylistRepo wiring — Track A's `PlaylistRepoImpl` adapts the open
// `CacheDb` to the engine's `PlaylistRepo` port. The trackId in the
// engine corresponds to `tracks.id` (SQLite autoincrement primary
// key) — that's what slice 4's vec0 schema keys on, and what
// `PlaylistRepoImpl.knnByEmbedding` returns. The mobile-side
// providers below bridge between `Track.path` and `tracks.id` via
// the live cache db.
// ---------------------------------------------------------------------------

/// Resolves the `PlaylistRepo` adapter for the open [CacheDb].
final playlistRepoProvider = FutureProvider<PlaylistRepo>((ref) async {
  final cache = await ref.watch(cacheDbProvider.future);
  return PlaylistRepoImpl(cache);
});

/// Process-singleton [RadioEngine] — stateless aside from its config,
/// so one instance is fine for the lifetime of the container.
final radioEngineProvider = Provider<RadioEngine>((_) => const RadioEngine());

/// Async-resolved [RecentSeedsStore]. Eagerly resolves the
/// `SharedPreferences` instance on first watch and caches it for the
/// lifetime of the container.
final recentSeedsStoreProvider =
    FutureProvider<RecentSeedsStore>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return RecentSeedsStore(prefs: prefs);
});

/// Cached snapshot of the recent-seeds list. Re-emitted whenever
/// [RadioSessionNotifier] persists a new seed.
final recentSeedsProvider =
    NotifierProvider<RecentSeedsNotifier, List<RecentSeedEntry>>(
  RecentSeedsNotifier.new,
);

class RecentSeedsNotifier extends Notifier<List<RecentSeedEntry>> {
  @override
  List<RecentSeedEntry> build() {
    // Kick off the prefs load and publish when ready.
    Future<void>(() async {
      final store = await ref.watch(recentSeedsStoreProvider.future);
      if (state.isEmpty) {
        state = store.load();
      }
    });
    return const <RecentSeedEntry>[];
  }

  /// Inserts (or refreshes) [entry] at the head and persists. The
  /// resulting list replaces [state].
  Future<void> upsert(RecentSeedEntry entry) async {
    final store = await ref.read(recentSeedsStoreProvider.future);
    final updated = await store.upsert(entry);
    state = updated;
  }
}

/// Sync helper used by [LookaheadManager] to translate a picked
/// `trackId` (== `tracks.id` in the cache DB) into a live [Track]
/// row from the in-memory merged track set.
typedef TrackByIdLookup = Track? Function(int);

/// Map from `tracks.id` (cache DB autoincrement) to absolute path.
/// Refreshes whenever the cache db is reopened — pre-loaded once per
/// session-start so [LookaheadManager]'s synchronous lookup hits
/// memory, not SQLite.
///
/// The query is sub-ms on a 5k library and the resulting map is a
/// few hundred KB; refreshing on each [trackByIdLookupProvider]
/// rebuild (i.e. when the cache db handle changes or
/// `trackWithPatchProvider` re-emits) keeps the id space in sync
/// with what the ingest coordinator wrote.
///
/// Promoted from `_idToPathProvider` in slice 10 to expose a testing
/// seam for [RadioSessionNotifier.buildClusterSession].
final idToPathProvider = FutureProvider<Map<int, String>>((ref) async {
  final cache = await ref.watch(cacheDbProvider.future);
  final rows = await cache.writer.rawQuery(
    "SELECT id, path FROM tracks WHERE status = 'ready'",
  );
  return {
    for (final r in rows) r['id'] as int: r['path'] as String,
  };
});

/// Provides a synchronous `id → Track` lookup by joining the cache
/// db's `id ↔ path` map with the merged in-memory track set. Returns
/// null when the cache hasn't loaded yet or the track has been
/// removed since the session started (§10 risk 4 — re-ingest
/// reassigned ids).
final trackByIdLookupProvider = Provider<TrackByIdLookup>((ref) {
  final mergedAsync = ref.watch(trackWithPatchProvider);
  final idMapAsync = ref.watch(idToPathProvider);
  final tracks = mergedAsync.asData?.value.tracks ?? const <Track>[];
  final idToPath = idMapAsync.asData?.value ?? const <int, String>{};
  final byPath = <String, Track>{for (final t in tracks) t.path: t};
  return (int id) {
    final path = idToPath[id];
    if (path == null) return null;
    return byPath[path];
  };
});

/// Inverse map — `path → tracks.id` — used by
/// [RadioSessionNotifier.startFromTrack] and
/// [RadioSessionNotifier.buildClusterSession] to resolve a `Track`'s
/// engine-id at session boot. Built lazily off the same source as
/// [idToPathProvider] so the two stay consistent.
final pathToIdProvider = FutureProvider<Map<String, int>>((ref) async {
  final idMap = await ref.watch(idToPathProvider.future);
  return {
    for (final entry in idMap.entries) entry.value: entry.key,
  };
});

// ---------------------------------------------------------------------------
// RadioSession + LookaheadManager
// ---------------------------------------------------------------------------

final radioSessionProvider =
    NotifierProvider<RadioSessionNotifier, RadioSession?>(
  RadioSessionNotifier.new,
);

/// Derived flag — true while a radio session is running. Widgets that
/// gate visibility on radio mode (`RadioBadge`, `SteerChipBar`) read this.
final radioModeProvider =
    Provider<bool>((ref) => ref.watch(radioSessionProvider) != null);

/// The live [LookaheadManager], or null when no session is running.
/// Exposed for tests + future debug instrumentation; the
/// `RadioSessionNotifier` is the canonical owner of the manager
/// lifetime, so widget code should generally not interact with this
/// provider directly — read [radioSessionProvider] instead.
final lookaheadProvider = Provider<LookaheadManager?>((ref) {
  // Watching the session triggers a rebuild every time the manager
  // is replaced (start / stop). The notifier holds the manager as a
  // private field; we expose it through a getter on the notifier for
  // diagnostic-only consumers.
  ref.watch(radioSessionProvider);
  final notifier = ref.read(radioSessionProvider.notifier);
  return notifier.lookaheadManager;
});

class RadioSessionNotifier extends Notifier<RadioSession?> {
  LookaheadManager? _manager;

  /// Read-only access to the live manager — diagnostic-only.
  /// `lookaheadProvider` exposes this; widget code should
  /// generally not reach for it.
  LookaheadManager? get lookaheadManager => _manager;

  @override
  RadioSession? build() {
    ref.onDispose(() {
      // Fire-and-forget — manager dispose is async; container is
      // tearing down anyway.
      // ignore: discarded_futures
      _manager?.dispose();
    });
    return null;
  }

  Future<void> startFromTrack(Track track) async {
    assert(() {
      debugPrint(
        '[RadioDiag] startFromTrack input path=${track.path} '
        'title=${track.title}',
      );
      return true;
    }());
    final repo = await ref.read(playlistRepoProvider.future);
    final pathToId = await ref.read(pathToIdProvider.future);
    final id = pathToId[track.path];
    if (id == null) {
      // No cache row for this path — track hasn't been ingested yet
      // (e.g. fresh scan still in flight). Surface to the caller; UI
      // can show a "Library still indexing" snackbar.
      assert(() {
        debugPrint(
          '[RadioDiag] startFromTrack abort: no cache_db row for '
          '${track.path}',
        );
        return true;
      }());
      throw StateError(
        'no cache_db row for ${track.path}; library ingest may still be '
        'in progress',
      );
    }
    assert(() {
      debugPrint(
        '[RadioDiag] startFromTrack resolved id=$id; building RadioSession',
      );
      return true;
    }());
    final session = await RadioEngine.fromTrack(
      trackId: id,
      title: track.title ?? _basename(track.path),
      repo: repo,
    );
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'track',
        ref: '$id',
        label: track.title ?? _basename(track.path),
        lastUsedAt: DateTime.now(),
      ),
    );
    assert(() {
      debugPrint('[RadioDiag] startFromTrack end (manager booted)');
      return true;
    }());
  }

  Future<void> startFromAlbum({
    required String albumKey,
    required String title,
  }) async {
    final repo = await ref.read(playlistRepoProvider.future);
    final session = await RadioEngine.fromAlbum(
      albumKey: albumKey,
      title: title,
      repo: repo,
    );
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'album',
        ref: albumKey,
        label: title,
        lastUsedAt: DateTime.now(),
      ),
    );
  }

  Future<void> startFromArtist({
    required String artist,
    required String label,
  }) async {
    final repo = await ref.read(playlistRepoProvider.future);
    final session = await RadioEngine.fromArtist(
      artist: artist,
      label: label,
      repo: repo,
    );
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'artist',
        ref: artist,
        label: label,
        lastUsedAt: DateTime.now(),
      ),
    );
  }

  /// Public for testing — constructs the session without booting the
  /// lookahead manager. Returns `null` when zero tracks resolve to an
  /// embedding (slice 10 §7 risk 5: empty-cluster fallback).
  @visibleForTesting
  Future<RadioSession?> buildClusterSession(
    List<Track> tracks, {
    String? steeringHint,
  }) async {
    if (tracks.isEmpty) return null;
    final repo = await ref.read(playlistRepoProvider.future);
    final pathToId = await ref.read(pathToIdProvider.future);
    final ids = <int>[];
    final vectors = <Float32List>[];
    for (final t in tracks) {
      final id = pathToId[t.path];
      if (id == null) continue;
      try {
        final v = await repo.embeddingOf(id);
        ids.add(id);
        vectors.add(v);
      } catch (_) {
        // Embedding row missing or wrong length — skip and try the
        // next. Slice-5 risk 8 already surfaces dimension drift via
        // ArgumentError; we swallow it here because skipping one track
        // is preferable to blowing up the cluster boot.
      }
    }
    final seedEmbedding = RadioEngine.averageEmbeddings(vectors);
    if (seedEmbedding == null) return null;
    final label = steeringHint ?? 'Cluster (${ids.length})';
    return RadioSession(
      seed: ClusterSeed(
        trackIds: List<int>.unmodifiable(ids),
        label: label,
        steeringHint: steeringHint,
      ),
      seedEmbedding: seedEmbedding,
    );
  }

  /// Slice 10 §2.3 — third radio entry point. Treats [tracks] as a
  /// synthetic cluster, averages their embeddings, and feeds the result
  /// through the same kNN entry as the slice-5 paths.
  ///
  /// Tracks whose path doesn't resolve to a `tracks.id` are skipped.
  /// When ZERO resolve, the call short-circuits with no state change —
  /// the end-of-playlist sheet's "Can't extend this playlist yet" copy
  /// is the surface that explains this to the user.
  Future<void> startFromCluster(
    List<Track> tracks, {
    String? steeringHint,
  }) async {
    final session =
        await buildClusterSession(tracks, steeringHint: steeringHint);
    if (session == null) return;
    final cluster = session.seed as ClusterSeed;
    await _bootSession(
      session,
      RecentSeedEntry(
        kind: 'cluster',
        ref: cluster.trackIds.join(','),
        label: cluster.label,
        lastUsedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _bootSession(
    RadioSession session,
    RecentSeedEntry seedEntry,
  ) async {
    final repo = await ref.read(playlistRepoProvider.future);
    final engine = ref.read(radioEngineProvider);
    final queue = ref.read(queueProvider.notifier);
    final lookup = ref.read(trackByIdLookupProvider);
    final playback = ref.read(playbackServiceProvider);

    // Tear down any prior manager + ring before booting the new one
    // so a re-seed doesn't double-listen to the index stream.
    await _manager?.dispose();
    final manager = LookaheadManager(
      repo: repo,
      engine: engine,
      queue: queue,
      trackByIdLookup: lookup,
    );
    _manager = manager;

    await manager.start(
      initial: session,
      currentIndexStream: playback.currentIndexStream,
    );

    // Pull the post-prime session (5 picks have been made) and
    // publish.
    state = manager.session;

    // Slice-11 §A1 fix — kick playback so the user actually hears the
    // first radio track. `LookaheadManager.start` appends 5 tracks
    // through `QueueService.appendForRadio`; the first one is promoted
    // to `current` (slice-11 §A1 fix in queue_service.dart). But the
    // player only auto-resumes when `wasPlaying=true` in
    // `syncSnapshot`; if the user long-pressed without anything
    // playing, `wasPlaying=false` and the first source loads silently.
    // Calling `play()` here makes the long-press → "Radio started"
    // affordance produce sound on cold-start. No-op when something was
    // already playing (`play` on an already-playing player is idempotent).
    assert(() {
      debugPrint(
        '[RadioDiag] _bootSession manager booted; ringLen='
        '${manager.ring.length}; calling playback.play()',
      );
      return true;
    }());
    // ignore: discarded_futures — fire-and-forget; the service serialises
    // its own operations and we don't want to gate the snackbar on the
    // first-frame audio decode.
    playback.play();

    // Persist to recent seeds.
    await ref.read(recentSeedsProvider.notifier).upsert(seedEntry);
  }

  /// Toggles [chip] on at full strength. Per slice 5 §10 risk 10,
  /// this also requeues the lookahead tail so the new vibe takes
  /// effect within ~1 pick.
  Future<void> toggleChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    final updated = current.withChipToggled(chip);
    state = updated;
    final manager = _manager;
    if (manager == null) return;
    await manager.requeueTail(updatedSession: updated);
  }

  /// Clears [chip] regardless of its current state.
  Future<void> clearChip(SteerChip chip) async {
    final current = state;
    if (current == null) return;
    final updated = current.withChipCleared(chip);
    state = updated;
    final manager = _manager;
    if (manager == null) return;
    await manager.requeueTail(updatedSession: updated);
  }

  /// Stops the active session. The queue's PlayNext + Upcoming tails
  /// are left untouched — the user keeps anything that was already
  /// queued; only future picks stop being appended.
  Future<void> stop() async {
    await _manager?.stop();
    state = null;
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    final base = i < 0 ? path : path.substring(i + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}
