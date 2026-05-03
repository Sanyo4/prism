/// `CactusModelSpec` — the immutable manifest pinning a HuggingFace
/// revision of the Cactus-Compute INT4 Qwen3 weights, plus the
/// expected SHA256 digest the on-disk `.partial` rename pivots on.
///
/// All values are doc-refresh outputs (see
/// `docs/notes/slice-08-doc-refresh.md`). The pin must be revisited
/// alongside any Cactus SDK upgrade per slice-8 §10 risk 5.
library;

import 'package:meta/meta.dart';

/// Static manifest for a single Cactus-format model snapshot. Field
/// values come from the Git LFS pointer at the pinned HF revision
/// — never from `main`.
@immutable
class CactusModelSpec {
  /// Fully-resolved download URL — points at a specific HF commit so
  /// re-downloading the same `revision` always yields the same
  /// bytes (`size` and `sha256Hex` confirm).
  final Uri weightsUrl;

  /// HuggingFace commit SHA pinned at refresh time. Avoid `main` —
  /// that's a moving target.
  final String revision;

  /// On-disk file name for the downloaded archive. Cactus's
  /// `cactusInit` consumes the unpacked directory; the `.zip` here
  /// is the wire format. The unzip step is owned by Track B's
  /// first-run UI in `apps/mobile`.
  final String fileName;

  /// Exact byte length the server's `Content-Length` (or sum of
  /// resumed `Content-Range` totals) must equal at completion.
  final int sizeBytes;

  /// Lowercase 64-char SHA256 digest of the downloaded file. **Empty
  /// string** signals a doc-refresh blocker — `ModelDownloader.start()`
  /// refuses to begin until this is populated. The pattern mirrors
  /// slice-3 Phase A's `ModelPin.sha256 == ''` raise.
  final String sha256Hex;

  const CactusModelSpec({
    required this.weightsUrl,
    required this.revision,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256Hex,
  });

  /// Convenience: did the refresh populate a real SHA256? Empty
  /// string means the manifest is incomplete and the downloader
  /// must refuse to start.
  bool get hasPin => sha256Hex.isNotEmpty;
}

/// Pinned manifest for `Cactus-Compute/Qwen3-1.7B` (INT4 packed format).
///
/// Pin sources (refreshed 2026-05-03):
///  - HF revision: commit `51397ee…b9c9b618e5` ("Upload v1.14").
///  - File: `weights/qwen3-1.7b-int4.zip` — 1,006,051,493 bytes,
///    SHA256 `a9d09c15…2c28ca802` per the Git LFS pointer.
///  - URL pattern: `huggingface.co/<repo>/resolve/<revision>/<path>`.
///
/// The repo also publishes `weights/qwen3-1.7b-int8.zip` (~1.73 GB);
/// we ship INT4 only per slice-8 §1 (footprint budget).
///
/// Declared `final` rather than `const` because `Uri.parse` is not a
/// `const` expression. The instance is still effectively immutable —
/// every field is `final`.
// ignore: non_constant_identifier_names
final CactusModelSpec kQwen3_1_7B_INT4 = CactusModelSpec(
  weightsUrl: Uri.parse(
    'https://huggingface.co/Cactus-Compute/Qwen3-1.7B/resolve/'
    '51397eec167a109d41c0006d37e780b9c9b618e5/'
    'weights/qwen3-1.7b-int4.zip',
  ),
  revision: '51397eec167a109d41c0006d37e780b9c9b618e5',
  fileName: 'qwen3-1.7b-int4.zip',
  sizeBytes: 1006051493,
  sha256Hex:
      'a9d09c15110b2977f6b71d393bbad4f9991b5d59638c413ea07c63d2c28ca802',
);
