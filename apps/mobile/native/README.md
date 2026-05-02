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

| Platform           | Path                                  | SHA-256                                                            |
| ------------------ | ------------------------------------- | ------------------------------------------------------------------ |
| Linux x86_64       | `linux/x86_64/vec0.so`                | `5923730861b86c707cca5602b5f91092f9e52a46706dbc6e269fd4bb9c4498e8` |
| Android arm64-v8a  | `android/arm64-v8a/vec0.so`           | `3083712f52da27a172469b34d1b82fe8388f2c76bc822b85ceaaed9f8e460c74` |
| Android x86_64     | `android/x86_64/vec0.so`              | `783080adf3a90a45fd6c8dc110a7e8d050acea03767caa076152163a13a77366` |

Verify with `sha256sum` from the repository root:

```bash
sha256sum apps/mobile/native/linux/x86_64/vec0.so \
          apps/mobile/native/android/arm64-v8a/vec0.so \
          apps/mobile/native/android/x86_64/vec0.so
```

### Sources

The `.so` files were extracted from the upstream release archives:

- `sqlite-vec-0.1.9-loadable-linux-x86_64.tar.gz`
- `sqlite-vec-0.1.9-loadable-android-aarch64.tar.gz`
- `sqlite-vec-0.1.9-loadable-android-x86_64.tar.gz`

Each archive contains exactly one file (`vec0.so`); we extract and
commit verbatim.

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

### glibc / NDK floor

- Linux: built against glibc 2.28+ per upstream notes. Verified working
  on Pop!_OS / Ubuntu 24.04 (glibc 2.39); older long-term-support
  distros on glibc 2.27 (Ubuntu 18.04, RHEL 8 pre-stream) will need a
  newer pin.
- Android: API 21+ (the `android-aarch64` archive is built against
  Android NDK r24+).

### Updating the pin

When bumping the release tag:

1. Download the three platform archives from the new release.
2. Extract each `vec0.so` into its existing target directory.
3. Re-run the `sha256sum` command above and update this file.
4. Run `flutter test` against `packages/core/test/migrations_test.dart`
   to confirm the extension still loads cleanly on Linux.
5. Spot-check the Android side by re-running the §11 Verification
   matrix on a physical device or x86_64 emulator.

A version bump that changes the on-disk `vec0` virtual-table layout
**must** be paired with a `Migrations` schema-version bump so existing
caches rebuild cleanly.
