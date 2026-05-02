import 'dart:convert';
import 'dart:io';

import 'sidecar.dart';
import 'staleness.dart';

/// Result of reading one `<track>.sonic.json` from disk. Sealed so
/// `IngestCoordinator` can pattern-match on the outcome — promote a
/// `SidecarReady` to `status='ready'`, leave a `SidecarStale` /
/// `SidecarMissing` row at `status='analysis_pending'`.
sealed class SidecarReadResult {
  const SidecarReadResult();
}

/// Parsed cleanly and passes every staleness check.
final class SidecarReady extends SidecarReadResult {
  final Sidecar sidecar;
  const SidecarReady(this.sidecar);
}

/// File exists but should not be promoted. Carries [reason] for
/// surfacing in Settings ("3 sidecars stale; running an indexer pass
/// will fix them") and a free-form [detail] for INFO-log breadcrumbs.
final class SidecarStale extends SidecarReadResult {
  final StalenessReason reason;
  final String detail;
  const SidecarStale(this.reason, this.detail);
}

/// No sibling sidecar exists. Caller leaves the track at
/// `status='analysis_pending'` with tag metadata only.
final class SidecarMissing extends SidecarReadResult {
  const SidecarMissing();
}

/// Parses one sidecar file and reports whether ingest should accept it.
///
/// **Never throws.** Every failure mode (ENOENT, malformed JSON,
/// schema mismatch, conflict-copy filename, unexpected types) folds
/// into a `SidecarStale` or `SidecarMissing` — the ingest loop must
/// not crash on a single bad file.
///
/// Pure-Dart by design: callers in `apps/mobile` pass a `dart:io.File`
/// in; the reader doesn't itself reach for `path_provider` or any
/// Flutter API.
class SidecarReader {
  const SidecarReader();

  /// Read [file], returning a [SidecarReadResult]. The file's basename
  /// is consulted *before* I/O so Syncthing conflict copies are caught
  /// even when their JSON is otherwise valid.
  Future<SidecarReadResult> read(File file) async {
    if (_isConflictCopy(file.path)) {
      return SidecarStale(
        StalenessReason.conflictCopy,
        'sync-conflict sibling: ${file.path}',
      );
    }
    String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException {
      return const SidecarMissing();
    }
    return parse(raw);
  }

  /// Pure synchronous variant for callers who already have the bytes
  /// in memory (tests, in-isolate ingest of pre-read files).
  SidecarReadResult parse(String raw) {
    Object? decoded;
    try {
      decoded = json.decode(raw);
    } on FormatException catch (e) {
      return SidecarStale(
        StalenessReason.malformedJson,
        'json decode failed: ${e.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return SidecarStale(
        StalenessReason.malformedJson,
        'top-level JSON value is not an object',
      );
    }

    // Schema-version gate is cheap and runs *before* full
    // `Sidecar.fromJson` so a v2-of-the-future sidecar with a
    // restructured embedding doesn't blow up the parser.
    final schemaVersion = decoded['schema_version'];
    if (schemaVersion is! int ||
        schemaVersion != kCurrentSidecarSchemaVersion) {
      return SidecarStale(
        StalenessReason.schemaMismatch,
        'schema_version=$schemaVersion (expected $kCurrentSidecarSchemaVersion)',
      );
    }

    // Analyzer-model gate before parser so a missing-model rebuild
    // wouldn't be reported as malformed JSON.
    final modelsRaw = decoded['analyzer_models'];
    if (modelsRaw is! List ||
        modelsRaw.toSet().intersection(kCompatibleAnalyzerModels).isEmpty) {
      return SidecarStale(
        StalenessReason.analyzerMismatch,
        'analyzer_models=$modelsRaw',
      );
    }

    Sidecar sidecar;
    try {
      sidecar = Sidecar.fromJson(decoded);
    } on FormatException catch (e) {
      return SidecarStale(
        StalenessReason.malformedJson,
        'Sidecar.fromJson rejected: ${e.message}',
      );
    } catch (e) {
      // `_$SidecarFromJson` throws CheckedFromJsonException / TypeError
      // for unexpected types; lump everything into malformedJson so
      // the ingest loop never propagates an unexpected throw.
      return SidecarStale(
        StalenessReason.malformedJson,
        'Sidecar.fromJson threw $e',
      );
    }
    return SidecarReady(sidecar);
  }

  /// Returns `true` for paths whose basename matches Syncthing's
  /// conflict-copy convention: `<stem>.sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX.<ext>`.
  /// Slice-4 §10 risk 5 — never promote off a conflict file; the
  /// canonical sibling wins. Detection is filename-only; no I/O.
  static bool _isConflictCopy(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final name = slash < 0 ? path : path.substring(slash + 1);
    return name.contains('.sync-conflict-');
  }
}
