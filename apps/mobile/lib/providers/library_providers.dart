import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prism_core/core.dart';

/// Accumulator for [ScanFailed] events produced by the most recent run
/// of [tracksProvider]. Slice 1 only surfaces its length implicitly
/// (unused in the §11 verification matrix); a later slice will add a
/// Settings row to render the list so users can see which files
/// couldn't be parsed. Slice 2's goals list does not include this row —
/// it ships alongside the Android storage-access rework.
///
/// Behaviour:
/// - [build] returns an empty list at container construction.
/// - [append] is called once per [ScanFailed] emitted during the scan.
/// - [reset] wipes the list at the start of every new scan.
class LibraryScanFailuresNotifier extends Notifier<List<ScanFailed>> {
  @override
  List<ScanFailed> build() => const <ScanFailed>[];

  void append(ScanFailed failure) {
    state = <ScanFailed>[...state, failure];
  }

  void reset() {
    if (state.isEmpty) return;
    state = const <ScanFailed>[];
  }
}

/// Riverpod 3 wiring — `NotifierProvider.new` replaces the legacy
/// `StateProvider` that slice 1's plan originally referenced.
final libraryScanFailuresProvider =
    NotifierProvider<LibraryScanFailuresNotifier, List<ScanFailed>>(
  LibraryScanFailuresNotifier.new,
);

/// Resolves the directory the scanner should walk on launch.
///
/// Resolution precedence:
/// 1. `defaultLibraryRoot()` — platform-appropriate `~/Music` on Linux
///    or `/storage/emulated/0/Music` on Android, per `packages/core`.
/// 2. `getApplicationDocumentsDirectory()` — the Flutter fallback kept
///    out of `packages/core` to preserve its Flutter-free surface.
///
/// Returned as a [FutureProvider] so callers can watch it without
/// racing filesystem I/O during widget build.
final libraryRootProvider = FutureProvider<Directory>((ref) async {
  final preferred = defaultLibraryRoot();
  if (preferred != null) return preferred;
  return getApplicationDocumentsDirectory();
});

/// Tracks discovered by walking [libraryRootProvider] once, start to
/// finish.
///
/// Responsibilities:
/// - Kick off [LibraryScanner.scan] against the resolved root.
/// - Accumulate [ScanDiscovered.track] into the returned list.
/// - Forward [ScanFailed] events to [libraryScanFailuresProvider].
/// - Stop when [ScanDone] arrives.
/// - Cancel cooperatively via [CancellationToken] when the provider is
///   disposed (Riverpod destroys this provider when the last watcher
///   goes away, which is the signal we use here).
///
/// Dedup: tracks are keyed by [Track.path] — re-scans or symlinked
/// directories that surface the same file twice collapse to one entry,
/// so `ListView.builder` keys stay stable.
final tracksProvider = FutureProvider<List<Track>>((ref) async {
  final root = await ref.watch(libraryRootProvider.future);
  final token = CancellationToken();
  ref.onDispose(token.cancel);

  // Wipe prior failures at the start of each run so stale errors don't
  // linger across re-scans.
  ref.read(libraryScanFailuresProvider.notifier).reset();

  final scanner = LibraryScanner();
  final byPath = <String, Track>{};
  await for (final event in scanner.scan(root, token: token)) {
    switch (event) {
      case ScanDiscovered(:final track):
        byPath.putIfAbsent(track.path, () => track);
      case ScanFailed():
        ref.read(libraryScanFailuresProvider.notifier).append(event);
      case ScanSkipped():
        // Slice 1 drops skipped paths on the floor — the user doesn't
        // need a banner for "foo.txt isn't an audio file". Slice 2's
        // Settings row may expose them behind an "Advanced" toggle.
        break;
      case ScanDone():
        // Sealed-type switch still needs the terminal case even though
        // the stream closes right after — Dart's exhaustiveness checker
        // complains otherwise.
        break;
    }
  }
  return byPath.values.toList(growable: false);
});
