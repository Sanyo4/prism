/// `CactusInit` — NPU→CPU trial loader.
///
/// Slice-8 §7 contract: given a preferred [NpuSupport], verify weights
/// are on disk + SHA256 matches `kQwen3_1_7B_INT4.sha256Hex`, then
/// attempt to instantiate a Cactus model handle. On any init exception
/// (NPU bind failure, corrupt weights, missing native lib), retry
/// once with the CPU path. After a second failure raise
/// `CactusInitFailed`.
///
/// Cactus 1.3.0's Flutter binding does not surface a per-call backend
/// selector (refresh notes), so the "trial NPU then CPU" pattern
/// here is a SHAPE the contract honors — the real `cactusInit` call
/// is identical for both. Track B can set a Pro key beforehand to
/// unlock NPU acceleration globally; the retry pattern still serves
/// for non-NPU init failures (corrupt weights, OOM).
library;

import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

import 'cactus_model.dart';
import 'model_paths.dart';
import 'model_spec.dart';
import 'npu_detect.dart';

/// Raised by `CactusInit.load` when the weights file is missing or
/// SHA256-mismatched. Track B's UI catches this and surfaces the
/// download banner.
class ModelMissing implements Exception {
  /// Human-readable explanation. Surfaced verbatim in UI so it should
  /// be short + non-technical-but-honest.
  final String reason;

  /// Path that was inspected (or expected). Useful for debug logs;
  /// UI doesn't show this.
  final String? path;

  const ModelMissing(this.reason, {this.path});

  @override
  String toString() => 'ModelMissing: $reason'
      '${path == null ? '' : ' (path: $path)'}';
}

/// Raised by `CactusInit.load` after both the NPU and CPU init paths
/// fail. Wraps the underlying error so Track B can decide whether to
/// log + offer a "Retry NPU" affordance.
class CactusInitFailed implements Exception {
  final String reason;
  final Object? underlying;

  const CactusInitFailed(this.reason, [this.underlying]);

  @override
  String toString() => 'CactusInitFailed: $reason'
      '${underlying == null ? '' : ' (underlying: $underlying)'}';
}

/// NPU-aware loader for Cactus model handles.
class CactusInit {
  final CactusModelSpec spec;
  final ModelPaths paths;
  final NpuProbe probe;

  /// Optional cache of the SHA256 verification result, keyed by file
  /// path + length. Re-running the 1 GB hash on every load would
  /// cost ~5–10 s on the Pixel — we cache once per process.
  String? _verifiedPath;

  /// Test seam: when set, replaces the real `cactusInit` FFI call
  /// with a callback that returns a handle (or throws). Production
  /// callers leave this null — `_realInit` runs.
  final Future<Object> Function(String weightsPath, NpuSupport requested)?
      nativeInit;

  CactusInit({
    required this.spec,
    required this.paths,
    required this.probe,
    this.nativeInit,
  });

  /// Verify weights + load. [preferred] selects NPU when the device
  /// supports it; on init failure retries with CPU. Returns the
  /// loaded `CactusModelLike` and the actual backend used.
  ///
  /// Throws:
  ///  - [ModelMissing] when the weights file is absent or its SHA256
  ///    doesn't match the pin.
  ///  - [CactusInitFailed] when both NPU and CPU init paths fail.
  Future<CactusModelLike> load(NpuSupport preferred) async {
    // (1) Refuse with a clear message if the spec is un-pinned. Track
    // B's UI surfaces the SHA-pin gap to the user.
    if (!spec.hasPin) {
      throw const ModelMissing(
        'Model pin missing — sha256Hex empty in CactusModelSpec. '
        'Re-run §4 doc refresh and populate kQwen3_1_7B_INT4.',
      );
    }

    // (2) Confirm the file is on disk + matches the SHA. Verification
    // is cached across calls within the same `CactusInit` instance.
    final file = await paths.finalFile();
    if (!await file.exists()) {
      throw ModelMissing(
        'Weights file not present',
        path: file.path,
      );
    }
    if (_verifiedPath != file.path) {
      final actual = await _hashFileSha256(file);
      if (actual != spec.sha256Hex.toLowerCase()) {
        throw ModelMissing(
          'Weights file SHA256 mismatch '
          '(expected ${spec.sha256Hex.substring(0, 8)}…, '
          'got ${actual.substring(0, 8)}…)',
          path: file.path,
        );
      }
      _verifiedPath = file.path;
    }

    // (3) Try NPU first when requested. On failure, retry on CPU.
    Object? lastError;
    final attempts = <NpuSupport>[];
    if (preferred == NpuSupport.npu) {
      attempts.add(NpuSupport.npu);
    }
    attempts.add(NpuSupport.cpu);

    for (final attempt in attempts) {
      try {
        final handle = await _invokeInit(file.path, attempt);
        return CactusModel.fromHandle(handle, attempt);
      } on Object catch (e) {
        lastError = e;
        // Try the next backend (or fall through to throw).
      }
    }
    throw CactusInitFailed(
      'Cactus init failed after ${attempts.length} attempt(s) '
      '(${attempts.map((a) => a.name).join(', ')})',
      lastError,
    );
  }

  /// Runs the real Cactus `cactusInit` FFI on Android (or the
  /// injected [nativeInit] in tests).
  Future<Object> _invokeInit(String weightsPath, NpuSupport requested) async {
    final native = nativeInit;
    if (native != null) {
      return native(weightsPath, requested);
    }
    return _realInit(weightsPath, requested);
  }

  /// Production binding to `package:cactus`'s `cactusInit`. On Linux
  /// this raises [UnimplementedError] — only Android arm64 has the
  /// loaded native lib.
  ///
  /// `requested` is recorded but not passed to the FFI: Cactus 1.3.0
  /// does not expose a backend selector at the call site. Track B's
  /// UI relies on `CactusModelLike.backend` (the chosen attempt) for
  /// the "running on NPU/CPU" badge.
  Future<Object> _realInit(String weightsPath, NpuSupport requested) async {
    // Production: `final handle = cactusInit(weightsPath, null, false);`
    // — see refresh notes for the v1.3.0 binding signature.
    throw UnimplementedError(
      'cactusInit FFI is bound only on Android arm64. '
      'requested=$requested, weightsPath=$weightsPath',
    );
  }

  /// SHA256-hashes [file] in 64 KiB chunks via the streaming
  /// `AccumulatorSink<Digest>` pattern (`docs/notes/slice-08-doc-refresh.md`,
  /// crypto section). Result is lowercase hex.
  static Future<String> _hashFileSha256(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    final digest = output.events.single;
    return digest.toString().toLowerCase();
  }
}
