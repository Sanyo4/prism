/// `ModelPaths` — resolves on-disk paths for a [CactusModelSpec],
/// rooted at the platform's app-documents directory.
///
/// Constructor takes an injectable `Future<Directory>` so tests can
/// supply a tmp directory without going through `path_provider`'s
/// platform channel (which fails outside a Flutter binding).
/// Production callers pass `getApplicationDocumentsDirectory()` from
/// `package:path_provider`.
///
/// Layout under the docs dir:
///   `<docs>/llm_models/<fileName>`           (final)
///   `<docs>/llm_models/<fileName>.partial`   (resumable in-progress)
library;

import 'dart:async';
import 'dart:io';

import 'model_spec.dart';

class ModelPaths {
  /// Future resolving to the app-documents-equivalent directory the
  /// caller should use as the root. In production this is
  /// `getApplicationDocumentsDirectory()` from `path_provider`; tests
  /// inject a tmp dir.
  final Future<Directory> Function() rootDirProvider;

  /// Sub-directory name inside the root, kept simple. The dir is
  /// auto-created by [finalFile] / [partialFile] before the path is
  /// returned so callers can write immediately.
  static const String _subdir = 'llm_models';

  /// Active spec; used to derive [fileName] and `<fileName>.partial`.
  final CactusModelSpec spec;

  ModelPaths({
    required this.rootDirProvider,
    required this.spec,
  });

  /// Returns the absolute path to the final, verified weights file
  /// (post-rename). Creates the parent directory if missing.
  Future<File> finalFile() async {
    final root = await rootDirProvider();
    final dir = Directory('${root.path}/$_subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/${spec.fileName}');
  }

  /// Returns the absolute path to the in-progress `.partial` file.
  /// Creates the parent directory if missing. Survives app kill so
  /// the next launch can resume via `Range: bytes=<existing>-`.
  Future<File> partialFile() async {
    final root = await rootDirProvider();
    final dir = Directory('${root.path}/$_subdir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/${spec.fileName}.partial');
  }
}
