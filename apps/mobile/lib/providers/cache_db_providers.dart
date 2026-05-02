import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:prism_core/core.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqflite.dart' show DatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Process-wide [CacheDb] handle. Opens lazily on first watch; the
/// `ref.onDispose` closure releases both SQLite handles when the
/// container is disposed (i.e. on full app teardown).
///
/// Failure mode: if the platform doesn't ship a vec0 prebuilt or the
/// `.so` is corrupt, this provider rethrows. UI layers that depend on
/// the cache (Mood / Vibe screens) gate on the AsyncValue so failure
/// surfaces as an inline error rather than a crash.
final cacheDbProvider = FutureProvider<CacheDb>((ref) async {
  final factory = await _resolveDatabaseFactory();
  final supportDir = await getApplicationSupportDirectory();
  final dbDir = Directory(p.join(supportDir.path, 'prism'));
  if (!dbDir.existsSync()) {
    dbDir.createSync(recursive: true);
  }
  final dbPath = p.join(dbDir.path, 'cache.db');
  final vec0Path = await _resolveVec0Path(supportDir);
  final db = await CacheDb.open(
    factory: factory,
    path: dbPath,
    vec0Path: vec0Path,
  );
  ref.onDispose(db.close);
  return db;
});

/// Cache stats — read-once when the Settings screen renders. Refreshes
/// implicitly when the underlying CacheDb gets re-watched after an
/// ingest run.
final cacheStatsProvider = FutureProvider<CacheStats>((ref) async {
  final db = await ref.watch(cacheDbProvider.future);
  return CacheStats.compute(db);
});

/// Path → measured RG (dB) map. Populated as a one-shot read off the
/// cache; updates when the cache underneath changes. Slice-4
/// PlaybackService injects a synchronous lookup that consults this
/// map.
///
/// Sized at one row per `status='ready'` track. At 5 k tracks that's
/// ~80 KB — cheap enough to keep in memory.
final measuredReplayGainProvider =
    FutureProvider<Map<String, double>>((ref) async {
  final db = await ref.watch(cacheDbProvider.future);
  final rows = await db.writer.rawQuery('''
    SELECT path, replaygain_track_db
      FROM tracks
     WHERE status = 'ready'
       AND replaygain_track_db IS NOT NULL
  ''');
  return {
    for (final r in rows)
      r['path'] as String: (r['replaygain_track_db'] as num).toDouble(),
  };
});

/// Synchronous lookup used by PlaybackService. Re-reads the underlying
/// AsyncValue on every call — riverpod gives us O(1) access and
/// safely returns null while the future is still loading.
double? Function(Track) measuredRgLookupOf(Ref ref) {
  return (track) {
    final asyncMap = ref.read(measuredReplayGainProvider);
    final map = asyncMap.asData?.value;
    return map?[track.path];
  };
}

// --- platform plumbing -----------------------------------------------------

Future<DatabaseFactory> _resolveDatabaseFactory() async {
  if (Platform.isAndroid) {
    return sqflite.databaseFactory;
  }
  ffi.sqfliteFfiInit();
  return ffi.databaseFactoryFfi;
}

/// Resolves the platform-correct vec0.so path. On Android we copy the
/// asset out of `flutter_assets` to `<support>/native/vec0.so` once
/// (if not already present) and load from there — `dart:ffi`
/// `DynamicLibrary.open` doesn't read from the asset bundle. On
/// Linux we fall back to `Vec0Loader.resolvePath()` which finds the
/// committed binary via the search path documented in
/// `apps/mobile/native/README.md`.
Future<String> _resolveVec0Path(Directory supportDir) async {
  if (Platform.isLinux) {
    return Vec0Loader.resolvePath();
  }
  if (Platform.isAndroid) {
    final abi = await _resolveAndroidAbi();
    final assetKey = 'native/android/$abi/vec0.so';
    final destDir = Directory(p.join(supportDir.path, 'native'));
    if (!destDir.existsSync()) destDir.createSync(recursive: true);
    final destPath = p.join(destDir.path, 'vec0.so');
    final dest = File(destPath);
    if (!dest.existsSync()) {
      // First-launch copy. Subsequent launches reuse the file —
      // saves ~150 KB per launch and keeps the asset bundle
      // path-stable across app updates as long as we don't bump the
      // pin (when we do, we delete + recopy; see step 14 below).
      final bytes = await rootBundle.load(assetKey);
      await dest.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    }
    return destPath;
  }
  throw UnsupportedError(
    'vec0 not pre-built for ${Platform.operatingSystem}',
  );
}

Future<String> _resolveAndroidAbi() async {
  final info = await DeviceInfoPlugin().androidInfo;
  final abis = info.supported64BitAbis;
  if (abis.contains('arm64-v8a')) return 'arm64-v8a';
  if (abis.contains('x86_64')) return 'x86_64';
  throw UnsupportedError(
    'No 64-bit ABI prebuilt for vec0 — got ${info.supportedAbis}. '
    'armeabi-v7a is not supported in slice 4.',
  );
}
