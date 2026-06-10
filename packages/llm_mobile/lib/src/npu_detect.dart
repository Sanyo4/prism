/// `NpuProbe` — runtime feature probe for Cactus's NPU acceleration.
///
/// Slice-8 §7 declares three states: `npu` (NPU bind would succeed),
/// `cpu` (NPU absent / driver-blocked but ARMv8.2-A+ SIMD path works),
/// `unsupported` (older ARM / x86 / Linux desktop dev box).
///
/// Refresh notes call out that Cactus 1.3.0's Flutter binding does
/// **not** expose a per-call `backend` selector; NPU acceleration is
/// gated behind a Pro key (`CactusConfig.setProKey(...)`). We treat
/// `NpuSupport` as a record of capability — Track B's UI badges
/// "NPU" / "CPU" / "Unsupported" — rather than a literal init flag.
/// `MobileBackend.activeBackend` reflects detection, not configuration.
///
/// `detect()` is total — never throws. Linux dev box always returns
/// `unsupported`, mirroring the impossibility of loading Cactus's
/// native binaries on x86_64. Tests pin this without an Android
/// emulator.
library;

import 'dart:io' show Platform;

/// Three-state capability tag. Stable across the package's public API.
enum NpuSupport { npu, cpu, unsupported }

/// Single-shot probe. Construct fresh per-process — the result is
/// process-scoped (NPU drivers don't appear/disappear between probes).
///
/// **Linux/x86 always returns `unsupported`** because the Cactus
/// native side cannot load on a non-Android-arm64 host. On Android,
/// the probe consults `Platform.operatingSystem` plus an internal
/// best-effort hint about the Cactus runtime; the brief allows a Cactus
/// capability call here, but Cactus 1.3.0 does not expose one in Dart.
/// Until it does, Android probes return `cpu` (the safe lower bound)
/// and Track B's first init pass surfaces `activeBackend = cpu` for
/// the "Running on CPU — slower but works offline" banner.
class NpuProbe {
  NpuProbe();

  /// Capability lookup. Total — exceptions are swallowed and surfaced
  /// as `unsupported` so init paths never crash on the probe.
  Future<NpuSupport> detect() async {
    try {
      if (!Platform.isAndroid) {
        return NpuSupport.unsupported;
      }
      // Android arm64 — at minimum we know SIMD CPU works for
      // Cactus's INT4 kernels (Pixel 9 Pro Fold's Tensor G4 floors
      // at ARMv8.2-A). NPU bind probing requires Cactus's native
      // side, which we exercise indirectly via `CactusInit.load`'s
      // try/catch path, not here. Track B can pivot the return to
      // `npu` when the SDK exposes a probe-safe API.
      return NpuSupport.cpu;
    } on Object {
      // `Platform.isAndroid` itself can throw on truly unsupported
      // hosts (e.g. wasm); be defensive.
      return NpuSupport.unsupported;
    }
  }
}
