import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Accumulator for [ScanFailed] events produced by the most recent run
/// of [tracksProvider]. Slice 1 only surfaces its length implicitly
/// (unused in the §11 verification matrix); a later slice will add a
/// Settings row to render the list so users can see which files
/// couldn't be parsed. Slice 2's goals list does not include this row —
/// it ships alongside the Android storage-access rework.
///
/// Behaviour:
/// - [build] returns an empty list at container construction.
/// - [append] is called once per [ScanFailed] emitted during the scan.
/// - [reset] wipes the list at the start of every new scan.
class LibraryScanFailuresNotifier extends Notifier<List<ScanFailed>> {
  @override
  List<ScanFailed> build() => const <ScanFailed>[];

  void append(ScanFailed failure) {
    state = <ScanFailed>[...state, failure];
  }

  void reset() {
    if (state.isEmpty) return;
    state = const <ScanFailed>[];
  }
}

/// Riverpod 3 wiring — `NotifierProvider.new` replaces the legacy
/// `StateProvider` that slice 1's plan originally referenced.
final libraryScanFailuresProvider =
    NotifierProvider<LibraryScanFailuresNotifier, List<ScanFailed>>(
  LibraryScanFailuresNotifier.new,
);

/// Resolves the directory the scanner should walk on launch.
///
/// Resolution precedence:
/// 1. `defaultLibraryRoot()` — platform-appropriate `~/Music` on Linux
///    or `/storage/emulated/0/Music` on Android, per `packages/core`.
/// 2. `getApplicationDocumentsDirectory()` — the Flutter fallback kept
///    out of `packages/core` to preserve its Flutter-free surface.
///
/// Returned as a [FutureProvider] so callers can watch it without
/// racing filesystem I/O during widget build.
final libraryRootProvider = FutureProvider<Directory>((ref) async {
  final preferred = defaultLibraryRoot();
  if (preferred != null) return preferred;
  return getApplicationDocumentsDirectory();
});

/// Guard: `true` while a background [scanInIsolate] is running.
/// Prevents the invalidate-triggered second build from firing a second
/// concurrent scan. Module-level so it survives provider rebuilds.
bool _scanInFlight = false;

/// Performs the diff-and-persist step after the live scan completes,
/// then returns the updated track list from the cache.
///
/// 1. Upsert new / changed rows (path absent or mtime changed).
/// 2. Delete rows for paths no longer on the filesystem.
/// 3. Re-read the cache so the returned list is consistent with what
///    was persisted.
Future<void> _reconcile(
  CacheDb db,
  List<Track> live,
) async {
  final livePaths = <String>{for (final t in live) t.path};
  final cachedMtimes = await db.tracksCache.readPathMtimes();

  final toUpsert = <Track>[];
  for (final t in live) {
    final cachedMtime = cachedMtimes[t.path];
    if (cachedMtime == null || cachedMtime != t.mtimeMs) {
      toUpsert.add(t);
    }
  }
  if (toUpsert.isNotEmpty) {
    await db.tracksCache.upsertAll(toUpsert);
  }

  await db.tracksCache.deletePathsNotIn(livePaths);
}

/// Tracks discovered by walking [libraryRootProvider].
///
/// Slice-10b §D3' — two-phase cold-start with DB-failure fallback:
///
/// **Phase 1 (warm read):** Reads from `tracks_cache` immediately.
/// Emits the cached list to consumers in <10 ms on subsequent
/// launches, so the Albums / Artists grids are populated well before
/// the FS walk finishes.
///
/// **Phase 2 (background scan):** Calls [scanInIsolate] so the FS
/// walk + tag parsing run off the UI thread. When the scan completes,
/// the results are diffed against the cached mtimes:
/// - New/changed rows are upserted.
/// - Paths missing from the live set are deleted.
/// - This provider is then invalidated so consumers see the fresh
///   data.
///
/// **DB-failure fallback (slice-10b §D3'):** If [cacheDbProvider]
/// throws (e.g. the vec0 migration crash on Android before §A1' was
/// applied, or any other DB open failure), the warm-cache read is
/// skipped and [scanInIsolate] is called directly — the same
/// pre-D3 behaviour that always worked regardless of cache.db health.
/// Albums / Artists / Library all continue to render even when
/// cache.db is broken.
///
/// **First-launch sync scan:** When the cache is empty (first install
/// or after a DB wipe), the live scan runs synchronously so the first
/// frame shows tracks immediately rather than an empty grid waiting
/// for the Phase-2 side-effect to finish.
///
/// **Pattern chosen:** `FutureProvider<List<Track>>` + side-effect
/// kick-off + `ref.invalidate`. This preserves the `AsyncValue<List<Track>>`
/// contract that all existing consumers rely on (`ref.watch` + `.when` /
/// `.whenData` / `.asData?.value`). Consumers that call
/// `ref.read(tracksProvider.future)` also continue to work unchanged.
/// The alternative (NotifierProvider emitting twice) would require
/// updating every consumer that assumes the standard FutureProvider API.
///
/// **Loop prevention:** `_scanInFlight` (module-level) ensures only
/// one background scan runs at a time. The invalidate-triggered second
/// build skips the kick-off and returns the already-updated cache.
///
/// Dedup: tracks are keyed by [Track.path] in `tracks_cache`, so
/// re-scans or symlinked directories that surface the same file twice
/// collapse to one entry.
final tracksProvider = FutureProvider<List<Track>>((ref) async {
  final root = await ref.watch(libraryRootProvider.future);

  // Wipe prior failures at the start of each (re-)scan.
  ref.read(libraryScanFailuresProvider.notifier).reset();

  // Try the warm-cache path. If cache.db is unhealthy (e.g. vec0 DDL
  // crash on Android before §A1' landed, or any other open failure),
  // fall through to a direct isolate scan so albums still load.
  // Slice-10b §D3' — wraps the D3 warm-cache read in try-catch.
  CacheDb? db;
  try {
    db = await ref.read(cacheDbProvider.future);
  } catch (e) {
    // ignore: avoid_print
    print('tracksProvider: cache.db unavailable, falling back to '
        'direct FS scan: $e');
    // No cache → just scan and return. Albums/Artists still render.
    try {
      return await scanInIsolate(root);
    } catch (scanErr, scanSt) {
      Error.throwWithStackTrace(scanErr, scanSt);
    }
  }

  // Phase 1: warm read from tracks_cache.
  // On first install this is empty; subsequent launches return the
  // persisted list immediately without any FS I/O.
  // db is non-null here: the catch block always returns or rethrows.
  final cached = await db!.tracksCache.readAll();

  // Phase 2: background live scan. Only kick off one scan at a time.
  // When the FutureProvider is invalidated after the scan finishes,
  // this second build re-reads the updated cache and skips the kickoff.
  if (!_scanInFlight) {
    _scanInFlight = true;
    // ignore: discarded_futures — intentional fire-and-forget background task.
    () async {
      try {
        final live = await scanInIsolate(root);
        await _reconcile(db!, live);
        // Invalidate so consumers rebuild with the fresh cache data.
        ref.invalidateSelf();
      } catch (_) {
        // Scan failed: leave the cached payload as-is; consumers
        // already have a valid (if stale) list from Phase 1.
      } finally {
        _scanInFlight = false;
      }
    }();
  }

  // First cold launch when cache is empty: if Phase 2 hasn't populated
  // yet, run the scan synchronously so albums DO appear on first launch
  // (instead of an empty grid waiting for the side-effect to finish).
  if (cached.isEmpty) {
    try {
      final live = await scanInIsolate(root);
      await _reconcile(db, live);
      return live;
    } catch (e) {
      // Scan failed too — return empty rather than crash.
      // ignore: avoid_print
      print('tracksProvider first-launch scan failed: $e');
      return const <Track>[];
    }
  }

  // Return the warm-cache payload immediately. If this is the second
  // build triggered by the invalidate, this is now the updated list.
  return cached;
});
