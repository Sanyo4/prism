/// Prism playlist engine — pure-Dart, platform-agnostic.
///
/// Slice 5 ships [RadioEngine] (seed-kNN + steer chips). Slice 6 will
/// add `PlaylistEngine` next to it sharing [FlowScorer] and [Camelot]
/// without modification — the public surface here is the API stability
/// contract that protects that future work.
///
/// **Hard import constraints (slice 5 §6):**
///   - Imports only `dart:typed_data`, `dart:math`, `package:meta`,
///     `package:collection`.
///   - Zero `package:flutter`, `dart:io`, `package:sqlite3`,
///     `package:prism_core`.
///   - All storage access goes through the [PlaylistRepo] port;
///     `packages/core/lib/src/db/playlist_repo_impl.dart` ships the
///     SQLite-backed implementation.
library;

export 'camelot.dart';
export 'chip_weights.dart';
export 'flow.dart';
export 'pick_result.dart';
export 'radio_engine.dart';
export 'radio_session.dart';
export 'repo.dart';
export 'steer_chip.dart';
