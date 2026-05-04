import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

import '../providers/radio_providers.dart';

/// Material 3 modal bottom sheet for the long-press "Start radio
/// from this track" action.
///
/// **Track-only.** Album / artist / cluster seeds are not surfaced
/// through this sheet — radio is always seeded from a single track
/// (album-radio / artist-radio entry points were removed because the
/// "from this whole album" semantic confused users). The
/// [RadioContextSheet.show] entry point asserts on non-[TrackSeed] in
/// debug and returns early in release.
///
/// Used by every track-row surface that supports long-press:
/// - `album_detail_screen.dart`'s tracklist `ListTile`s.
/// - `playlist_detail_screen.dart`'s tracklist `ListTile`s.
/// - `artist_detail_screen.dart`'s top-tracks `ListTile`s.
/// - `songs_shuffle_tab.dart`'s deck rows.
/// - `queue_screen.dart`'s history / now-playing / mutable rows.
/// - `now_playing_screen.dart`'s title text.
///
/// The sheet is single-tile by design: there's exactly one action,
/// and tapping it starts radio + closes the sheet + shows the
/// "Radio started" snackbar. Future slices may add a "Add to recent
/// seeds without starting" sibling; not in scope for slice 5.
class RadioContextSheet {
  RadioContextSheet._();

  /// Opens the sheet for [seed]. Tapping the tile delegates to
  /// `radioSessionProvider.notifier.startFromTrack`, dismisses the
  /// sheet, and shows a "Radio started" snackbar.
  ///
  /// [seed] **must** be a [TrackSeed]. Album / artist / cluster seeds
  /// trigger an `assert` in debug builds and a silent no-op in release
  /// — the slice-5 `startFromAlbum` / `startFromArtist` entry points
  /// on the notifier still exist (kept as dead code per the slice-5
  /// invariant that the state machine is byte-identical), but the UI
  /// no longer routes to them.
  static Future<void> show(BuildContext context, SeedRef seed) {
    assert(
      seed is TrackSeed,
      'RadioContextSheet.show only supports TrackSeed; got '
      '${seed.runtimeType}. Album / artist / cluster radio entry '
      'points were removed.',
    );
    if (seed is! TrackSeed) {
      return Future<void>.value();
    }
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                seed.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: Text(_kindLabel(seed)),
            ),
            const Divider(height: 1),
            Consumer(
              builder: (context, ref, _) => ListTile(
                leading: const Icon(Icons.radio_outlined),
                title: Text('Start radio from this ${_kindWord(seed)}'),
                onTap: () => _start(context, sheetContext, ref, seed),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Convenience for callers that already have a [Track] in hand —
  /// builds a [TrackSeed] internally. Used by the library long-press
  /// sheet's third tile (which doesn't open this sheet itself).
  static Future<void> startFromTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    // Slice-11 §A1 — short-circuit when vec0 isn't loaded so the user
    // sees an honest error instead of "Radio started" with no music.
    if (Vec0Loader.loadFailed) {
      assert(() {
        debugPrint(
          '[RadioDiag] startFromTrack(convenience) blocked: '
          'Vec0Loader.loadFailed=true (${Vec0Loader.loadFailureMessage})',
        );
        return true;
      }());
      _snack(context, 'Radio unavailable — embeddings disabled');
      return;
    }
    await ref.read(radioSessionProvider.notifier).startFromTrack(track);
    if (context.mounted) _snack(context, 'Radio started');
  }

  static Future<void> _start(
    BuildContext context,
    BuildContext sheetContext,
    WidgetRef ref,
    SeedRef seed,
  ) async {
    Navigator.of(sheetContext).pop();
    // Slice-11 §A1 — vec0 degraded mode produces a "Radio started"
    // snackbar but no audio. Detect early and replace the snackbar
    // copy with an honest "Radio unavailable" message.
    if (Vec0Loader.loadFailed) {
      assert(() {
        debugPrint(
          '[RadioDiag] _start blocked: Vec0Loader.loadFailed=true '
          '(${Vec0Loader.loadFailureMessage})',
        );
        return true;
      }());
      if (context.mounted) {
        _snack(context, 'Radio unavailable — embeddings disabled');
      }
      return;
    }
    final notifier = ref.read(radioSessionProvider.notifier);
    switch (seed) {
      case TrackSeed():
        // Resolve the live Track row from id; bail silently if the
        // file went away mid-session (shouldn't happen — we just
        // long-pressed it).
        final lookup = ref.read(trackByIdLookupProvider);
        final track = lookup(seed.trackId);
        if (track == null) return;
        await notifier.startFromTrack(track);
      case AlbumSeed():
      case ArtistSeed():
      case ClusterSeed():
        // Non-track seeds never enter this sheet — the [show] guard
        // already short-circuits before reaching here. Treated as a
        // silent no-op for defence-in-depth: a future caller that
        // forgets the assert won't crash, and the slice-5
        // `startFromAlbum` / `startFromArtist` notifier entry points
        // (kept as dead code per the byte-identical state-machine
        // invariant) remain unwired.
        return;
    }
    if (context.mounted) _snack(context, 'Radio started');
  }

  static void _snack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  static String _kindLabel(SeedRef seed) {
    switch (seed) {
      case TrackSeed():
        return 'Track';
      case AlbumSeed():
        return 'Album';
      case ArtistSeed():
        return 'Artist';
      case ClusterSeed():
        return 'Cluster';
    }
  }

  static String _kindWord(SeedRef seed) {
    switch (seed) {
      case TrackSeed():
        return 'track';
      case AlbumSeed():
        return 'album';
      case ArtistSeed():
        return 'artist';
      case ClusterSeed():
        return 'cluster';
    }
  }
}
