/// `ModelDownloader` — resumable, SHA256-verified download of the
/// pinned Cactus weights archive.
///
/// Slice-8 §10 risk surface lives here:
///  - Risk 2 (insufficient disk space): pre-check `statFs(appDocsDir)`
///    via `Directory.parent` lookup; need `sizeBytes + 256 MB` buffer.
///  - Risk 4 (partial on app kill): writes to `<file>.partial`; next
///    `start()` resumes via `Range: bytes=<existing>-`.
///  - Risk 8 (SHA256 mismatch): delete partial, surface
///    `DownloadPhase.failed` with "checksum mismatch".
///  - Empty-pin refusal (slice-3 Phase A parity): refuse to start
///    when `spec.sha256Hex == ''`.
///
/// Dio is the only HTTP transport. `pause()` cancels the in-flight
/// `CancelToken`, leaving `.partial` intact for resume.
library;

import 'dart:async';
import 'dart:io';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'model_paths.dart';
import 'model_spec.dart';

/// Phases the downloader transitions through. Renders 1:1 to the UI's
/// state machine.
enum DownloadPhase {
  /// Pre-flight: SHA-pin populated, disk space free, request issued
  /// but no first byte yet. UI shows "Connecting…".
  connecting,

  /// Streaming bytes; `receivedBytes` and `bytesPerSecond` update.
  downloading,

  /// All bytes received; SHA256 streaming hash in progress. UI shows
  /// "Verifying…" — usually < 5 s.
  verifying,

  /// Hash matched; `.partial` renamed → final. Terminal.
  done,

  /// User-initiated `pause()`. `.partial` preserved; `start()` resumes.
  paused,

  /// Download failed (network error, hash mismatch, disk full,
  /// missing pin). Terminal until UI re-issues `start()`.
  failed,
}

/// One progress sample. Fields default to safe values when unknown
/// (e.g. `bytesPerSecond == 0` before the first sample).
class DownloadProgress {
  final DownloadPhase phase;
  final int receivedBytes;

  /// Total expected bytes. `-1` when the server doesn't supply
  /// Content-Length (rare for HF). UI should fall back to a
  /// determinate-but-unknown bar in that case.
  final int totalBytes;

  /// Rolling 5-second average bytes/s. Zero before first sample and
  /// inside `paused` / `verifying` / `done` / `failed`.
  final double bytesPerSecond;

  /// Computed from `bytesPerSecond` + remaining bytes; null when the
  /// rate is too unstable to extrapolate.
  final Duration? eta;

  /// Populated only on `failed`. Plain English; surfaced verbatim.
  final String? errorMessage;

  const DownloadProgress({
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
    this.bytesPerSecond = 0,
    this.eta,
    this.errorMessage,
  });

  @override
  String toString() => 'DownloadProgress(phase: ${phase.name}, '
      'recv: $receivedBytes/$totalBytes, '
      'bps: ${bytesPerSecond.toStringAsFixed(0)}, '
      'eta: $eta'
      '${errorMessage == null ? '' : ', err: $errorMessage'})';
}

/// Resumable downloader. Construct once per spec; tear down via the
/// implicit garbage collection of the `progress` controller.
class ModelDownloader {
  final Dio _dio;
  final CactusModelSpec spec;
  final ModelPaths paths;

  /// Required free-disk buffer above the spec's `sizeBytes`. Default
  /// 256 MB — slice-8 §10 risk 2 threshold.
  final int diskHeadroomBytes;

  /// Active cancel token. `pause()` cancels; the next `start()`
  /// allocates a fresh one.
  CancelToken? _cancel;

  /// Broadcast progress controller. Safe for multiple subscribers.
  final StreamController<DownloadProgress> _progress =
      StreamController<DownloadProgress>.broadcast();

  /// One-time SHA256 verification cache for the final file. Set after
  /// the first successful `isComplete()` returns true.
  bool? _verifiedComplete;

  ModelDownloader(
    this._dio,
    this.spec,
    this.paths, {
    this.diskHeadroomBytes = 256 * 1024 * 1024,
  });

  /// Broadcast stream of `DownloadProgress` events. Multiple
  /// listeners safe; the UI's progress card and a debug log can both
  /// subscribe.
  Stream<DownloadProgress> get progress => _progress.stream;

  /// Begins (or resumes) the download. Idempotent against the
  /// completed state — calling `start()` after a successful `done`
  /// emits `done` immediately and returns.
  Future<void> start() async {
    // (a) Empty-pin refusal — mirrors slice-3 Phase A.
    if (!spec.hasPin) {
      _emit(const DownloadProgress(
        phase: DownloadPhase.failed,
        receivedBytes: 0,
        totalBytes: -1,
        errorMessage: 'Download blocked: pin missing. Refresh model spec.',
      ));
      return;
    }

    // (b) Already complete? Short-circuit.
    if (await isComplete()) {
      _emit(DownloadProgress(
        phase: DownloadPhase.done,
        receivedBytes: spec.sizeBytes,
        totalBytes: spec.sizeBytes,
      ));
      return;
    }

    final finalFile = await paths.finalFile();
    final partialFile = await paths.partialFile();
    final existing = await partialFile.exists()
        ? await partialFile.length()
        : 0;

    // (c) Disk-space pre-check (slice-8 §10 risk 2). Only check when
    // there's enough info to do it without false positives.
    final needed = spec.sizeBytes - existing + diskHeadroomBytes;
    final free = await _freeDiskBytes(partialFile.parent);
    if (free != null && free < needed) {
      _emit(DownloadProgress(
        phase: DownloadPhase.failed,
        receivedBytes: existing,
        totalBytes: spec.sizeBytes,
        errorMessage: 'Not enough space. Free at least '
            '${(needed / (1024 * 1024)).round()} MB.',
      ));
      return;
    }

    final cancel = _cancel = CancelToken();
    _emit(DownloadProgress(
      phase: DownloadPhase.connecting,
      receivedBytes: existing,
      totalBytes: spec.sizeBytes,
    ));

    // Range request when we have an existing partial.
    final headers = <String, Object>{};
    if (existing > 0) {
      headers['Range'] = 'bytes=$existing-';
    }

    // Rolling 5-s rate sampler.
    final samples = <(_DurationStamp, int)>[];
    var lastEmit = DateTime.now();

    try {
      await _dio.download(
        spec.weightsUrl.toString(),
        // dio writes to a temp path then atomically renames; we want
        // it appended to .partial when resuming. The FileAccess is
        // controlled via the `fileAccess` option — append when
        // resuming, write fresh otherwise. dio defaults: it deletes
        // the existing file before writing unless `fileAccess` is
        // append. The 5.x API names this `FileAccessMode`.
        partialFile.path,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
        deleteOnError: false,
        cancelToken: cancel,
        fileAccessMode:
            existing > 0 ? FileAccessMode.append : FileAccessMode.write,
        onReceiveProgress: (recv, total) {
          // `recv` is the count for THIS request only — when resuming,
          // `existing` was already on disk before the dio call.
          final realReceived = existing + recv;
          final realTotal = total > 0 ? existing + total : spec.sizeBytes;

          // Rate sampling — drop samples older than 5 s.
          final now = DateTime.now();
          samples.add((_DurationStamp(now), realReceived));
          while (samples.length > 1 &&
              now.difference(samples.first.$1.at).inMilliseconds > 5000) {
            samples.removeAt(0);
          }
          final bps = samples.length >= 2
              ? _computeBps(samples)
              : 0.0;
          final remaining = realTotal - realReceived;
          final eta = bps > 1024
              ? Duration(seconds: (remaining / bps).round())
              : null;

          // Emit-throttle to ~5 events/s so the stream doesn't flood.
          if (now.difference(lastEmit).inMilliseconds < 200) return;
          lastEmit = now;
          _emit(DownloadProgress(
            phase: DownloadPhase.downloading,
            receivedBytes: realReceived,
            totalBytes: realTotal,
            bytesPerSecond: bps,
            eta: eta,
          ));
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _emit(DownloadProgress(
          phase: DownloadPhase.paused,
          receivedBytes: await _safeLength(partialFile),
          totalBytes: spec.sizeBytes,
        ));
        return;
      }
      _emit(DownloadProgress(
        phase: DownloadPhase.failed,
        receivedBytes: await _safeLength(partialFile),
        totalBytes: spec.sizeBytes,
        errorMessage: e.message ?? 'Network error',
      ));
      return;
    } catch (e) {
      _emit(DownloadProgress(
        phase: DownloadPhase.failed,
        receivedBytes: await _safeLength(partialFile),
        totalBytes: spec.sizeBytes,
        errorMessage: e.toString(),
      ));
      return;
    } finally {
      if (identical(_cancel, cancel)) {
        _cancel = null;
      }
    }

    // (d) Verify the assembled file's SHA256.
    _emit(DownloadProgress(
      phase: DownloadPhase.verifying,
      receivedBytes: await _safeLength(partialFile),
      totalBytes: spec.sizeBytes,
    ));
    final actual = await _hashFileSha256(partialFile);
    if (actual != spec.sha256Hex.toLowerCase()) {
      // SHA mismatch — drop the partial so the next start() does a
      // clean fetch.
      try {
        await partialFile.delete();
      } on Object {
        // ignore
      }
      _emit(DownloadProgress(
        phase: DownloadPhase.failed,
        receivedBytes: 0,
        totalBytes: spec.sizeBytes,
        errorMessage: 'Checksum mismatch. Tap to retry.',
      ));
      return;
    }

    // (e) All good — atomic rename.
    if (await finalFile.exists()) {
      try {
        await finalFile.delete();
      } on Object {
        // ignore
      }
    }
    await partialFile.rename(finalFile.path);
    _verifiedComplete = true;
    _emit(DownloadProgress(
      phase: DownloadPhase.done,
      receivedBytes: spec.sizeBytes,
      totalBytes: spec.sizeBytes,
    ));
  }

  /// Cancels the in-flight download. Idempotent. `.partial` is left
  /// on disk so the next `start()` resumes via `Range`.
  Future<void> pause() async {
    final c = _cancel;
    if (c != null && !c.isCancelled) {
      c.cancel('user-pause');
    }
  }

  /// True iff the final file exists AND its on-disk SHA256 matches
  /// the pinned digest. The verification result is memoized — the
  /// 1 GB hash takes a few seconds and shouldn't run on every UI tick.
  Future<bool> isComplete() async {
    if (_verifiedComplete == true) return true;
    if (!spec.hasPin) return false;
    final file = await paths.finalFile();
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length != spec.sizeBytes) return false;
    final actual = await _hashFileSha256(file);
    final ok = actual == spec.sha256Hex.toLowerCase();
    _verifiedComplete = ok;
    return ok;
  }

  void _emit(DownloadProgress p) {
    if (_progress.isClosed) return;
    _progress.add(p);
  }

  /// Best-effort free-bytes lookup for [dir]. Linux + Android use
  /// `df` semantics through `Directory.statSync`'s parent — but Dart
  /// doesn't expose statvfs directly, so we fall back to `null`
  /// (skipping the disk check) when we can't determine. Tests
  /// inject an override via subclassing if needed.
  Future<int?> _freeDiskBytes(Directory dir) async {
    try {
      // Best-effort: shell out to `df --output=avail -B1 <dir>`. On
      // hosts without df (some Android shells) we return null and
      // skip the check. The brief calls for `statFs` — Dart core
      // doesn't ship that, and we can't add `package:disk_space`
      // without expanding the dependency surface.
      final result = await Process.run(
        'df',
        ['--output=avail', '-B1', dir.path],
        runInShell: false,
      );
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim().split('\n');
      if (out.length < 2) return null;
      return int.tryParse(out.last.trim());
    } on Object {
      return null;
    }
  }

  static Future<int> _safeLength(File f) async {
    try {
      if (await f.exists()) return await f.length();
    } on Object {
      // ignore
    }
    return 0;
  }

  /// Stream-hash the file. Mirror of `CactusInit._hashFileSha256` —
  /// duplicated here so this file doesn't depend on `cactus_init.dart`.
  static Future<String> _hashFileSha256(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString().toLowerCase();
  }

  /// Linear regression on the last 5 s of (timestamp, bytes) samples.
  /// We don't bother with anything fancier — the rate is for ETA
  /// display, not control loops.
  static double _computeBps(List<(_DurationStamp, int)> samples) {
    if (samples.length < 2) return 0;
    final first = samples.first;
    final last = samples.last;
    final dtMs = last.$1.at.difference(first.$1.at).inMilliseconds;
    if (dtMs <= 0) return 0;
    final dBytes = last.$2 - first.$2;
    return dBytes / (dtMs / 1000.0);
  }
}

/// Wrapper around `DateTime` to keep the records in a tuple readable.
class _DurationStamp {
  final DateTime at;
  const _DurationStamp(this.at);
}
