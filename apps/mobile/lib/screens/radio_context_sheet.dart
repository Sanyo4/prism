import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';

import '../providers/radio_providers.dart';

/// Material 3 modal bottom sheet for the long-press "Start radio
/// from this ___" action.
///
/// Used by:
/// - `library_screen.dart`'s `_SongsList` long-press — adds a third
///   tile to the existing Play Next / Add to Queue sheet (not this
///   sheet directly; library opens the sheet inline).
/// - `album_detail_screen.dart`'s album-cell long-press — opens the
///   sheet directly with an [AlbumSeed].
/// - `artist_detail_screen.dart`'s artist-cell long-press — opens
///   the sheet directly with an [ArtistSeed].
///
/// The sheet is single-tile by design: there's exactly one action,
/// and tapping it starts radio + closes the sheet + shows the
/// "Radio started" snackbar. Future slices may add a "Add to recent
/// seeds without starting" sibling; not in scope for slice 5.
class RadioContextSheet {
  RadioContextSheet._();

  /// Opens the sheet for [seed]. Tapping the tile delegates to the
  /// matching `radioSessionProvider.notifier.startFrom*`, dismisses
  /// the sheet, and shows a "Radio started" snackbar.
  ///
  /// Library long-press uses [seedTrack]; album/artist long-press
  /// passes [AlbumSeed] / [ArtistSeed].
  static Future<void> show(BuildContext context, SeedRef seed) {
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
        await notifier.startFromAlbum(
          albumKey: seed.albumKey,
          title: seed.title,
        );
      case ArtistSeed():
        await notifier.startFromArtist(
          artist: seed.artist,
          label: seed.label,
        );
      case ClusterSeed():
        // ClusterSeed never enters the long-press radio context sheet —
        // clusters seed sessions through the slice-10 'Keep playing'
        // flow at the end of an AI-Compose playlist. Treat as a no-op
        // here; the kind labels below still render gracefully so a
        // diagnostic surface re-using this sheet for a cluster won't
        // crash.
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
