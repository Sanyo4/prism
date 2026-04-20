import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import '../providers/library_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';

/// Flat list of every scanned track — tap to play, long-press for
/// queue actions.
///
/// Consumer architecture:
/// - Watches [tracksProvider] (`AsyncValue<List<Track>>`) for the
///   result of a scan kicked off by the provider's first `ref.watch`.
/// - Three UI branches: loading → spinner, error → error text, data →
///   [ListView.builder]. Empty data gets an informational empty state
///   so a user scanning an empty folder doesn't stare at a blank list.
/// - Tap calls `queueProvider.notifier.loadContext(...)` with the full
///   tracks list (start index = row index), then
///   `playbackServiceProvider.play()`. The queue is the single source
///   of truth — `PlaybackService` listens for the snapshot change and
///   rebuilds its source list, so we never double-drive the player.
/// - Long-press opens a Material 3 bottom sheet with `Play Next` and
///   `Add to Queue` (§11.8 verification). These call
///   `QueueService.playNext` / `addToUpcoming`; the snapshot-listener
///   in `playbackServiceProvider` then refreshes the player's source
///   list, preserving the current playback position so the injected
///   track lands gaplessly after (or above) the active row.
class TracksScreen extends ConsumerWidget {
  const TracksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(tracksProvider);
    return AppShell(
      title: 'Tracks',
      currentTab: AppTab.tracks,
      child: tracksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(error: error),
        data: (tracks) => tracks.isEmpty
            ? const _EmptyView()
            : _TracksList(tracks: tracks),
      ),
    );
  }
}

class _TracksList extends ConsumerWidget {
  const _TracksList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        return ListTile(
          title: Text(
            _displayTitle(t),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _subtitleOf(t) == null
              ? null
              : Text(
                  _subtitleOf(t)!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Text(_formatDuration(t.duration)),
          onTap: () => _playFrom(ref, i),
          onLongPress: () => _showTrackActions(context, ref, t),
        );
      },
    );
  }

  /// Loads [tracks] into the queue starting at [index], then plays.
  /// The queue provider's listener in `playbackServiceProvider` picks
  /// up the snapshot and rebuilds the player's source list before the
  /// [PlaybackService.play] call lands — both are idempotent so the
  /// ordering is cheap to reason about.
  void _playFrom(WidgetRef ref, int index) {
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: index);
    // Fire-and-forget — Material tap handlers can't be async, and the
    // play future resolves in milliseconds. Errors surface via the
    // player's state stream to the NowPlayingScreen.
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  /// Opens a Material 3 modal bottom sheet with the two queue-injection
  /// actions required by §11.8 of the slice-1 plan: `Play Next` (inserts
  /// at the head of the PlayNext zone, above any auto-queued context)
  /// and `Add to Queue` (appends to the tail of Upcoming, after all
  /// PlayNext entries). Both reuse the existing `QueueService` methods
  /// that already have unit coverage in `queue_service_test.dart`.
  ///
  /// UX notes:
  /// - We close the sheet before mutating the queue so the following
  ///   SnackBar lands on the parent `Scaffold` (the sheet has its own
  ///   route and would otherwise swallow the SnackBar).
  /// - Slice 1 accepts an edge case: if nothing is currently playing,
  ///   these actions queue the track but do not auto-start playback.
  ///   The user has to tap any row to kick off `loadContext` +
  ///   `play()`. A later slice can add smart-play-on-first-queue.
  void _showTrackActions(BuildContext context, WidgetRef ref, Track track) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                _displayTitle(track),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: _subtitleOf(track) == null
                  ? null
                  : Text(
                      _subtitleOf(track)!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play Next'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref.read(queueProvider.notifier).playNext(track);
                _snack(context, 'Added to Up Next');
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to Queue'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref.read(queueProvider.notifier).addToUpcoming(track);
                _snack(context, 'Added to queue');
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a short confirmation SnackBar on the root scaffold. Hides
  /// any prior SnackBar first so rapid repeated queue actions don't
  /// pile up a visible stack.
  void _snack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// Presentation fallback for an untagged file: filename without its
/// extension. Matches what Apple Music and the Files app surface for
/// rips with no ID3 / Vorbis title.
String _displayTitle(Track t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final path = t.path;
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

/// Joins `artist` and `album` with an em dash when either is present;
/// returns `null` when both are absent so the [ListTile] can drop
/// `subtitle` entirely and keep the row compact.
String? _subtitleOf(Track t) {
  final artist = t.artist ?? t.albumArtist;
  final album = t.album;
  if (artist == null && album == null) return null;
  if (artist == null) return album;
  if (album == null) return artist;
  return '$artist — $album';
}

/// `h:mm:ss` or `m:ss`, returning an em dash for unknown durations so
/// the trailing column never collapses to empty (which would visually
/// misalign adjacent rows).
String _formatDuration(Duration? d) {
  if (d == null) return '—';
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    final mm = m.toString().padLeft(2, '0');
    return '$h:$mm:$ss';
  }
  return '$m:$ss';
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No tracks found.\n\n'
          'Slice 1 scans the default music folder at launch '
          '(~/Music on Linux, /storage/emulated/0/Music on Android). '
          'A later slice will add a configurable scan path.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Scan failed: $error',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ),
    );
  }
}
