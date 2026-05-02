import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Symbol the upstream `vec0.so` exposes as its `sqlite3_extension_init`
/// alias. Verified by `nm -D vec0.so` against the v0.1.9 prebuilt.
const String _kVec0Symbol = 'sqlite3_vec_init';

/// Loads vec0 into the **process-wide** sqlite3 auto-extension list so
/// every subsequent `sqlite3.open` (read-side FFI handle, sqflite
/// write-side handle, even handles inside `Isolate.run`) sees the
/// `vec0` virtual-table module.
///
/// Idempotent: reloading the same shared library twice is a no-op —
/// sqlite3 deduplicates by entrypoint pointer. Safe to call from
/// every test as a setup step.
///
/// **Why process-wide?** sqflite (the write path) doesn't expose a
/// raw `Database` handle, so we can't call a per-handle
/// `loadExtension` on it. The auto-extension API hooks every newly-
/// opened handle, including the ones sqflite creates internally,
/// which is what makes `CREATE VIRTUAL TABLE … USING vec0` work
/// inside an sqflite transaction.
///
/// On failure the function throws — `CacheDb.open` catches and
/// degrades into "no embeddings" mode (slice-4 §10 risk 3).
class Vec0Loader {
  Vec0Loader._();

  /// Resolved + loaded `.so` path, kept around for diagnostics.
  static String? _loadedFrom;

  /// Path of the `.so` last used by [ensureLoaded]. `null` until first
  /// call. Surfaced by `CacheDb.diagnostic` for Settings rendering.
  static String? get loadedFrom => _loadedFrom;

  /// Idempotent registration of the vec0 entry point with the
  /// process-wide sqlite3 instance. After this returns, every
  /// `sqlite3.open(...)` will have vec0 available.
  ///
  /// [vec0Path] must point to the platform-correct `vec0.so`. Pass
  /// the result of [resolvePath] (or a test-injected path).
  static void ensureLoaded(String vec0Path) {
    if (_loadedFrom == vec0Path) return;
    final lib = DynamicLibrary.open(vec0Path);
    sqlite3.ensureExtensionLoaded(
      SqliteExtension.inLibrary(lib, _kVec0Symbol),
    );
    _loadedFrom = vec0Path;
  }

  /// Resolves the right `vec0.so` path for the current platform.
  ///
  /// Resolution order (Linux):
  /// 1. `PRISM_VEC0_PATH` env-var override (dev / CI).
  /// 2. Repo-root layout: `apps/mobile/native/linux/x86_64/vec0.so`
  ///    relative to the current working directory or to the resolved
  ///    executable. Used by `dart test` from the repo root.
  /// 3. Bundled-app layout: `<resolvedExecutable>/../lib/vec0.so` —
  ///    where Flutter places the asset for `flutter run -d linux`.
  ///
  /// On Android the caller is expected to copy the asset out of
  /// `flutter_assets` to `<support>/native/vec0.so` and pass that path
  /// in directly — the `dart:ffi` `DynamicLibrary.open` doesn't
  /// resolve assets natively. See `apps/mobile/lib/providers/
  /// cache_db_providers.dart` for the asset-copy code path.
  ///
  /// Throws [UnsupportedError] for platforms with no committed
  /// prebuilt; throws [FileSystemException] when the resolution finds
  /// no readable file.
  static String resolvePath() {
    final override = Platform.environment['PRISM_VEC0_PATH'];
    if (override != null && override.isNotEmpty) {
      if (!File(override).existsSync()) {
        throw FileSystemException(
          'PRISM_VEC0_PATH is set but file does not exist',
          override,
        );
      }
      return override;
    }
    if (Platform.isLinux) {
      // Search a small set of sensible places without leaning on
      // path_provider (which would force Flutter into packages/core).
      final candidates = <String>[
        // Repo-root tests / `dart test` invocations.
        'apps/mobile/native/linux/x86_64/vec0.so',
        // Same path resolved from the executable (covers `dart run`
        // when CWD isn't the repo root but the binary is).
        '${File.fromUri(Platform.script).parent.path}/../../apps/mobile/native/linux/x86_64/vec0.so',
        // Bundled Flutter desktop app — assets go next to the binary.
        '${File(Platform.resolvedExecutable).parent.path}/lib/vec0.so',
        '${File(Platform.resolvedExecutable).parent.path}/data/flutter_assets/native/linux/x86_64/vec0.so',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
      throw FileSystemException(
        'No vec0.so found. Tried: ${candidates.join(", ")}. '
        'Set PRISM_VEC0_PATH to override.',
        candidates.first,
      );
    }
    // Android resolution happens in apps/mobile (asset copy, ABI
    // probe) and the path is injected via `Vec0Loader.ensureLoaded`.
    // Other platforms aren't pinned in slice-4.
    throw UnsupportedError(
      'vec0 not pre-built for ${Platform.operatingSystem}; '
      'callers on Android must inject the path explicitly.',
    );
  }
}
