## sqlite-vec / vec0 prebuilt extension binaries

Slice 4 ships the [`sqlite-vec`](https://github.com/asg017/sqlite-vec)
loadable extension (`vec0`) as committed prebuilt `.so` files. The
extension provides the `vec0` virtual table that backs Prism's per-track
embedding kNN. We commit the binaries (instead of downloading at build
time) so:

1. Builds are fully offline-reproducible — the same discipline as
   slice 3's Essentia model pins.
2. Hash mismatch between the binary and the pin below is a loud,
   unambiguous failure (no silent ABI drift).
3. The Android phone can run airplane-mode without a build-time fetch.

### Upstream pin

- Repository: <https://github.com/asg017/sqlite-vec>
- Release tag: **`v0.1.9`** (latest stable as of 2026-05-02)
- License: MIT — see upstream repository

### File pins (SHA-256)

| Platform           | Path                                  | SHA-256                                                             | Page align |
| ------------------ | ------------------------------------- | ------------------------------------------------------------------- | ---------- |
| Linux x86_64       | `linux/x86_64/vec0.so`                | `5923730861b86c707cca5602b5f91092f9e52a46706dbc6e269fd4bb9c4498e8` | 4 KB       |
| Android arm64-v8a  | `android/arm64-v8a/vec0.so`           | `b2d853e1aa915d50872f4ddf65d2dd9616a46f86862d33cb0824fae18fedc9c5` | **16 KB**  |
| Android x86_64     | `android/x86_64/vec0.so`              | `2969cf4413cc0a529271b9f13094e9266be221fc91a9d1b94a2b358147d4afb3` | **16 KB**  |

Verify with `sha256sum` from the repository root:

```bash
sha256sum apps/mobile/native/linux/x86_64/vec0.so \
          apps/mobile/native/android/arm64-v8a/vec0.so \
          apps/mobile/native/android/x86_64/vec0.so
```

### Sources

The Linux `.so` was extracted from the upstream release archive:

- `sqlite-vec-0.1.9-loadable-linux-x86_64.tar.gz`

The **Android `.so` files were compiled from source** (not extracted from
the upstream archives) using NDK r28.2.13676358 with a 16 KB page-size
alignment flag (see "16 KB page-size compatibility" below). The upstream
release archives ship 4 KB-aligned binaries that `dlopen` rejects on
Android 15+ devices with a 16 KB memory page kernel (Pixel 9 series,
Tensor G4+).

### Runtime resolution

`packages/core/lib/src/db/vec_loader.dart` resolves the right `.so` at
open-time:

- **Linux desktop:** `dart test` and `flutter run -d linux` both look
  for the binary at `apps/mobile/native/linux/x86_64/vec0.so` (relative
  to the project root) or via the `PRISM_VEC0_PATH` env-var override.
  The bundled-app path is `resolvedExecutable/../lib/vec0.so` (Flutter
  copies the asset there at build time on Linux).
- **Android:** the right ABI is probed via
  `device_info_plus.supported64BitAbis` (`arm64-v8a` or `x86_64`); the
  asset is copied to `<getApplicationSupportDirectory>/native/vec0.so`
  on first launch and reused thereafter.

### 16 KB page-size compatibility (Android 15+ / Pixel 9 series)

Android 15 (API 35) introduced support for 16 KB memory pages, and
Google's Tensor G4+ SoCs (Pixel 9, Pixel 9 Pro, Pixel 9 Pro Fold) ship
with a 16 KB-page kernel by default. The Linux kernel rejects `dlopen`
of ELF shared libraries whose `LOAD` segment alignment is smaller than
the kernel's page size, producing an error like:

```
dlopen failed: "/data/.../vec0.so" has load segments that are not
page-size aligned
```

The upstream sqlite-vec v0.1.9 release archives were built with the
default 4 KB alignment (`Align 0x1000`). The Android `.so` files in this
repo are recompiled from source with:

```
-Wl,-z,max-page-size=16384
```

This produces `Align 0x4000` (16 KB) in all `LOAD` segments. Such
libraries are backward-compatible: a 4 KB kernel loads them at 4 KB
boundaries without issue.

**To rebuild the Android prebuilts** (e.g. when bumping the upstream version):

```bash
# Prerequisites
NDK=/home/sanyo/Android/Sdk/ndk/28.2.13676358  # NDK r28+
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64

# 1. Clone source
WORK=$(mktemp -d /tmp/sqlite-vec-build-XXXXXX)
git clone --depth 1 --branch v0.1.9 https://github.com/asg017/sqlite-vec.git "$WORK/sqlite-vec"
cd "$WORK/sqlite-vec"

# 2. Provide sqlite3 headers (not in repo; download amalgamation)
mkdir -p vendor
curl -fsSL "https://sqlite.org/2024/sqlite-amalgamation-3460000.zip" -o /tmp/sqlite-amalg.zip
unzip -j /tmp/sqlite-amalg.zip "*/sqlite3.h" "*/sqlite3ext.h" -d vendor/

# 3. Generate sqlite-vec.h from template
VERSION=$(cat VERSION)
DATE=$(date -r VERSION +'%FT%TZ%z')
SOURCE=$(git log -n 1 --pretty=format:%H -- VERSION)
VERSION_MAJOR=$(echo $VERSION | cut -d. -f1)
VERSION_MINOR=$(echo $VERSION | cut -d. -f2)
VERSION_PATCH=$(echo $VERSION | cut -d. -f3 | cut -d- -f1)
export VERSION DATE SOURCE VERSION_MAJOR VERSION_MINOR VERSION_PATCH
envsubst < sqlite-vec.h.tmpl > sqlite-vec.h

# 4. Build arm64-v8a (Pixel 9, standard Android devices)
$TOOLCHAIN/bin/aarch64-linux-android21-clang \
  -shared -fPIC -O2 \
  -I. -Ivendor \
  -Wl,-z,max-page-size=16384 \
  -Wl,-soname,vec0.so \
  -o "$WORK/vec0-arm64.so" \
  sqlite-vec.c

# 5. Build x86_64 (emulator)
$TOOLCHAIN/bin/x86_64-linux-android21-clang \
  -shared -fPIC -O2 \
  -I. -Ivendor \
  -Wl,-z,max-page-size=16384 \
  -Wl,-soname,vec0.so \
  -o "$WORK/vec0-x86_64.so" \
  sqlite-vec.c

# 6. Strip and verify
$TOOLCHAIN/bin/llvm-strip "$WORK/vec0-arm64.so" "$WORK/vec0-x86_64.so"
$TOOLCHAIN/bin/llvm-readelf -l "$WORK/vec0-arm64.so" | grep LOAD   # expect Align 0x4000
$TOOLCHAIN/bin/llvm-readelf --dyn-syms "$WORK/vec0-arm64.so" | grep sqlite3_vec_init

# 7. Copy into repo and update SHA-256 pins above
REPO=/home/sanyo/Projects/music-player
cp "$WORK/vec0-arm64.so"  "$REPO/apps/mobile/native/android/arm64-v8a/vec0.so"
cp "$WORK/vec0-x86_64.so" "$REPO/apps/mobile/native/android/x86_64/vec0.so"
sha256sum "$REPO/apps/mobile/native/android/arm64-v8a/vec0.so" \
          "$REPO/apps/mobile/native/android/x86_64/vec0.so"
```

Note: do **not** pass `-DSQLITE_CORE` when building a loadable extension.
That flag suppresses `SQLITE_EXTENSION_INIT2`, which is required for the
extension to access SQLite API functions at runtime.

### glibc / NDK floor

- Linux: built against glibc 2.28+ per upstream notes. Verified working
  on Pop!_OS / Ubuntu 24.04 (glibc 2.39); older long-term-support
  distros on glibc 2.27 (Ubuntu 18.04, RHEL 8 pre-stream) will need a
  newer pin.
- Android: API 21+ (`minSdkVersion 21`), built with NDK r28.2.13676358.
  The 16 KB `max-page-size` flag requires NDK r27 or newer (lld gains
  proper `max-page-size` support in that release).

### Updating the pin

When bumping the release tag:

1. **Linux:** download the new `sqlite-vec-X.Y.Z-loadable-linux-x86_64.tar.gz`
   release archive and extract `vec0.so` into `linux/x86_64/`.
2. **Android:** do **not** use the upstream Android release archives — they
   ship 4 KB-aligned binaries. Instead, run the build script in the
   "16 KB page-size compatibility" section above (update the `--branch`
   tag and the SQLite amalgamation URL as appropriate for the new version).
3. Re-run the `sha256sum` command above and update the pins table in this file.
4. Run `dart test` against `packages/core/test/migrations_test.dart` and
   `packages/core/test/knn_test.dart` to confirm the Linux extension loads
   cleanly.
5. Spot-check the Android side on a Pixel 9 series device (16 KB page
   kernel) and an older device or x86_64 emulator (4 KB page kernel).

A version bump that changes the on-disk `vec0` virtual-table layout
**must** be paired with a `Migrations` schema-version bump so existing
caches rebuild cleanly.
