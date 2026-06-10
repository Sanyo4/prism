# Slice 4 — doc-refresh notes (per §4)

Five-line summaries written **before** any Dart was touched. Captures
training-data drift caught at refresh time.

## sqflite (`sqflite_common` interface)

- `openDatabase(path, version: 1, onConfigure:, onCreate:, onUpgrade:)` is the entrypoint.
- `onConfigure` runs *before* schema callbacks — `PRAGMA journal_mode = WAL` lives here.
- `Database` exposes `transaction((txn) async {...})`, `batch()`, `execute`, `rawQuery`.
- The Flutter `sqflite` plugin handles Android; `sqflite_common_ffi` (ffi.databaseFactoryFfi after `sqfliteFfiInit()`) handles Linux desktop and `dart test`.
- No raw FFI handle is exposed — the vec0 read-path opens a *second* handle via `package:sqlite3` on the same file.

## sqlite3 (Dart FFI binding) — confirmed by probe

- API spelling: **process-wide auto-extension**, *not* per-database `loadExtension`.
- Pattern: `sqlite3.ensureExtensionLoaded(SqliteExtension.inLibrary(DynamicLibrary.open(soPath), 'sqlite3_vec_init'));` then `sqlite3.open(file)` to get a `Database`.
- `Database.select(sql, [params])` returns a `ResultSet`; `Database.execute(sql, [params])` runs DDL/DML.
- Bindings to PK + blob: prepared statements take a `Uint8List` for `BLOB` columns; vec0 also accepts the `'[a,b,...]'` JSON-array string form.
- `Database.dispose()` closes; multiple `sqlite3.open` handles on the same file work fine in WAL mode.

## sqlite3_flutter_libs

- Pure transitive dep — bundles SQLite for Android + Linux so `sqlite3` finds a `DynamicLibrary` without a system `libsqlite3.so`.
- Linux desktop: ships the bundled lib next to the executable; sqlite3.dart's `_defaultOpen` looks for the plugin symbol on `DynamicLibrary.executable()` and uses that.
- Android: same idea — JNI library is loaded by the plugin on app start.
- No API surface to call directly; presence in `dependencies:` is the contract.
- Pinned at `^0.5.27` (released 0.5.42 at refresh — both expose the same Dart-side surface).

## sqlite-vec / `vec0` — confirmed by Linux x86_64 probe (release v0.1.9)

- Loadable filename is `vec0.so` on Linux + Android. Entry symbol: `sqlite3_vec_init`.
- `vec_version()` returned `v0.1.9` after `ensureExtensionLoaded`.
- Virtual-table DDL: `CREATE VIRTUAL TABLE t USING vec0(track_id INTEGER PRIMARY KEY, embedding FLOAT[1280]);`
- kNN syntax (both shapes work):
  - `WHERE embedding MATCH ? AND k = ? ORDER BY distance` (canonical 0.1.x).
  - `WHERE embedding MATCH ? ORDER BY distance LIMIT k` (also accepted).
- Embedding payload is either `'[a,b,c,...]'` JSON-string or **little-endian IEEE-754 float32 `Uint8List`** (5120 bytes for 1280 dims). Both round-trip with identical distances.

## json_serializable / json_annotation / build_runner

- `@JsonSerializable()` on the dataclass; `factory X.fromJson(Map<String,dynamic>) => _$XFromJson(j);` + `Map<String,dynamic> toJson() => _$XToJson(this);`.
- `@JsonKey(name: 'audio_sha1')` maps snake → camel.
- Codegen invocation: `dart run build_runner build --delete-conflicting-outputs`.
- Unknown JSON keys are silently ignored by default — matches spec's forward-compat rule.
- `nullable: false` constructor parameters are validated at parse time; explicitly default fields with `defaultValue:` to tolerate missing optionals.

## path_provider

- `getApplicationSupportDirectory()` is the stable writable root on Linux (`~/.local/share/<app-id>/`) and Android (app-scoped storage).
- `getApplicationDocumentsDirectory()` is a fallback for non-platform code paths in slice 1; slice 4's `CacheDb` opens `<support>/prism/cache.db`.
- Stays out of `packages/core` — Flutter-only API; the `cache_db_providers.dart` in `apps/mobile` injects the path.
- `getApplicationCacheDirectory()` exists on most platforms but is not durable on Android — do **not** put `cache.db` there.
- iOS / macOS not in slice-4 scope (vec0 isn't pre-built for them).

## crypto

- `sha1.convert(bytes)` is one-shot; returns a `Digest` whose `.toString()` is the lowercase hex form (40 chars).
- For chunked input (large file's first/last MiB tamper sensor): `final out = AccumulatorSink<Digest>(); final s = sha1.startChunkedConversion(out); s.add(chunk); s.close();`.
- Phone never recomputes PCM SHA1 — that is the desktop indexer's job per §10 risk 4. Authoritative equality is `sidecar.audio_sha1` byte-for-byte.
- Re-import path: `package:crypto/crypto.dart` plus `package:convert/convert.dart` for the accumulator sink.

## device_info_plus

- Android-only field we need: `androidInfo.supported64BitAbis` returns the ABIs the runtime can dlopen (e.g. `['arm64-v8a']` on a Pixel; `['x86_64']` on emulators).
- 32-bit ABIs (`armeabi-v7a`) are *not* supported by vec0's prebuilts — slice-4 fails-soft into degraded mode if no 64-bit ABI is found.
- Used only inside `vec_loader.dart`'s Android branch; the Linux branch resolves a static path.
- `final info = await DeviceInfoPlugin().androidInfo;`
- iOS / macOS / Web have separate getters that are out of scope here.

## watcher (stretch — feature-flagged off)

- Skipped for slice 4. Manual Re-scan is canonical. Inotify on Android scoped storage is unreliable on older releases (§10 risk 11).
