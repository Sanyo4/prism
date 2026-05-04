import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

import '../providers/playback_providers.dart' show queueProvider;
import '../providers/radio_providers.dart';

/// Material 3 modal bottom sheet for the long-press track-row action set.
///
/// **Track-only.** Album / artist / cluster seeds are not surfaced
/// through this sheet — every action (Play next / Add to queue /
/// Start radio) only makes sense for a single track. The
/// [RadioContextSheet.show] entry point silently no-ops on
/// non-[TrackSeed] for defence in depth.
///
/// Used by every track-row surface that supports long-press:
/// - `album_detail_screen.dart`'s tracklist `ListTile`s.
/// - `playlist_detail_screen.dart`'s tracklist `ListTile`s.
/// - `artist_detail_screen.dart`'s top-tracks `ListTile`s.
/// - `songs_shuffle_tab.dart`'s deck rows.
/// - `queue_screen.dart`'s history / now-playing / mutable rows.
/// - `now_playing_screen.dart`'s title text.
///
/// **Slice-11 §B1.** Restored the slice-1 three-tile shape
/// (Play next | Add to queue | Start radio) after slice-10d collapsed
/// the sheet to a single radio-only tile. Each tile dismisses the
/// sheet and shows a snackbar describing the action taken. The radio
/// tile additionally short-circuits to "Radio unavailable" when
/// `Vec0Loader.loadFailed` is true (slice-11 §A1) — the queue actions
/// don't depend on embeddings and work regardless of vec0 state.
class RadioContextSheet {
  RadioContextSheet._();

  /// Opens the sheet for [seed]. The sheet renders three actions:
  ///
  /// 1. **Play next** — inserts the resolved track at the head of
  ///    `QueueZone.playNext` via `queueProvider.notifier.playNext`.
  /// 2. **Add to queue** — appends the track to the tail of
  ///    `QueueZone.upcoming` via `queueProvider.notifier.addToUpcoming`.
  /// 3. **Start radio** — delegates to
  ///    `radioSessionProvider.notifier.startFromTrack`, gated on
  ///    [Vec0Loader.loadFailed] so a degraded vec0 surfaces a clear
  ///    "Radio unavailable" snackbar instead of silently producing no
  ///    audio.
  ///
  /// [seed] is expected to be a [TrackSeed] — every long-press call
  /// site builds one from the row's `Track`. Non-[TrackSeed] inputs
  /// are silently ignored (early return) so a stale caller can't crash
  /// the app.
  static Future<void> show(BuildContext context, SeedRef seed) {
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
              subtitle: const Text('Track'),
            ),
            const Divider(height: 1),
            Consumer(
              builder: (context, ref, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.playlist_play),
                    title: const Text('Play next'),
                    onTap: () => _playNext(sheetContext, ref, seed),
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: const Text('Add to queue'),
                    onTap: () => _addToQueue(sheetContext, ref, seed),
                  ),
                  ListTile(
                    leading: const Icon(Icons.radio_outlined),
                    title: const Text('Start radio from this track'),
                    onTap: () => _start(context, sheetContext, ref, seed),
                  ),
                ],
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

  /// Slice-11 §B1 — Play Next tile handler. Resolves the live [Track]
  /// from the seed's `trackId` via [trackByIdLookupProvider] and
  /// delegates to `queueProvider.notifier.playNext`. Silently no-ops
  /// when the lookup misses (track went away mid-session).
  static Future<void> _playNext(
    BuildContext sheetContext,
    WidgetRef ref,
    SeedRef seed,
  ) async {
    Navigator.of(sheetContext).pop();
    if (seed is! TrackSeed) return;
    final lookup = ref.read(trackByIdLookupProvider);
    final track = lookup(seed.trackId);
    if (track == null) return;
    ref.read(queueProvider.notifier).playNext(track);
    if (sheetContext.mounted) _snack(sheetContext, 'Added to Play Next');
  }

  /// Slice-11 §B1 — Add to Queue tile handler. Appends to the tail of
  /// `QueueZone.upcoming` (slice-1's `addToUpcoming` API; the public
  /// label is "Add to queue" because that's the user-facing intent).
  /// Silently no-ops when the lookup misses.
  static Future<void> _addToQueue(
    BuildContext sheetContext,
    WidgetRef ref,
    SeedRef seed,
  ) async {
    Navigator.of(sheetContext).pop();
    if (seed is! TrackSeed) return;
    final lookup = ref.read(trackByIdLookupProvider);
    final track = lookup(seed.trackId);
    if (track == null) return;
    ref.read(queueProvider.notifier).addToUpcoming(track);
    if (sheetContext.mounted) _snack(sheetContext, 'Added to queue');
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
        // forgets the guard won't crash, and the slice-5
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
}
