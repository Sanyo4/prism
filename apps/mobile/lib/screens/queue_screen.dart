import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/radio_seed_header.dart';

/// Three-section queue view — History (read-only) / Now Playing /
/// Up Next (PlayNext, user-queued) / Upcoming (context, collapsible).
///
/// Each Up Next / Upcoming row carries a three-action overflow menu
/// (`Move up`, `Move down`, `Remove`) and a row tap that hoists the
/// track to `currentIndex + 1` and calls
/// [PlaybackService.skipToNext] — so a single tap becomes "play this
/// right now".
///
/// The top-bar `Clear Up Next` action delegates to
/// [QueueService.clearPlayNext]; it's disabled when the zone is
/// already empty so users don't tap a no-op.
///
/// **Upcoming is collapsible.** Slice 1's `loadContext(allTracks, ...)`
/// dumps the entire visible library into the Upcoming zone. On a
/// 5 k-track library that's visually and performance-wise untenable
/// if rendered eagerly. Apple Music / Spotify handle this by showing
/// only the user's explicit queue and collapsing playback context
/// behind a "Playing from: …" attribution. We mirror that: the header
/// is tappable, and the list only materializes when expanded.
///
/// Layout: one [CustomScrollView] of slivers. Each zone is either a
/// [SliverToBoxAdapter] (headers, small fixed content) or a
/// [SliverList.builder] (zones with variable length). The builder
/// variant is critical for Upcoming — a plain `ListView(children: […])`
/// would materialize thousands of widget descriptors per rebuild.
/// Slice 5's radio flow refills Upcoming continuously, so the
/// virtualized form keeps us honest ahead of time.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  /// Upcoming context visibility. Default collapsed: the most common
  /// in-session action is to check / reorder the user queue, not to
  /// scroll through the auto-queued context. Resets on each screen
  /// entry because [AppShell] uses `pushReplacementNamed` — fine UX
  /// (no persistence = no "why is this expanded again" surprise).
  bool _upcomingExpanded = false;

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(queueProvider);
    return AppShell(
      title: 'Queue',
      // Queue is reached via the Now Playing overlay's bottom
      // utility row, not from the bottom-nav itself; we map it to
      // Library for the highlighted tab so the back-stack reads
      // sensibly when the user pops out of Queue.
      currentTab: AppTab.library,
      // Slice 7 §13 — Queue is a least-accented surface, like Library.
      useAurora: AuroraVariant.library,
      actions: [
        IconButton(
          tooltip: 'Clear Up Next',
          icon: const Icon(Icons.playlist_remove),
          onPressed: snap.playNext.isEmpty
              ? null
              : () => ref.read(queueProvider.notifier).clearPlayNext(),
        ),
      ],
      child: snap.isEmpty
          ? const _EmptyQueueView()
          : _QueueSections(
              snapshot: snap,
              upcomingExpanded: _upcomingExpanded,
              onToggleUpcoming: () => setState(
                () => _upcomingExpanded = !_upcomingExpanded,
              ),
            ),
    );
  }
}

class _QueueSections extends ConsumerWidget {
  const _QueueSections({
    required this.snapshot,
    required this.upcomingExpanded,
    required this.onToggleUpcoming,
  });

  final QueueSnapshot snapshot;
  final bool upcomingExpanded;
  final VoidCallback onToggleUpcoming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pre-compute the flat offsets for each zone so row builders know
    // their absolute `move(from, to)` index without rewalking the
    // snapshot. See QueueSnapshot.flat for the canonical layout:
    // [...history, ?current, ...playNext, ...upcoming]. History
    // starts at 0; the other offsets follow from there.
    final hasCurrent = snapshot.current != null;
    final currentOffset = snapshot.history.length;
    final playNextStart = currentOffset + (hasCurrent ? 1 : 0);
    final upcomingStart = playNextStart + snapshot.playNext.length;
    final flatLen = snapshot.length;

    return CustomScrollView(
      slivers: [
        // ── History ───────────────────────────────────────────────
        const SliverToBoxAdapter(child: _SectionHeader(title: 'History')),
        if (snapshot.history.isEmpty)
          const SliverToBoxAdapter(
            child: _SectionPlaceholder('Nothing played yet.'),
          )
        else
          SliverList.builder(
            itemCount: snapshot.history.length,
            itemBuilder: (_, i) =>
                _HistoryRow(track: snapshot.history[i]),
          ),

        // ── Now Playing ───────────────────────────────────────────
        if (hasCurrent) ...[
          const SliverToBoxAdapter(
            child: _SectionHeader(title: 'Now Playing'),
          ),
          SliverToBoxAdapter(
            child: _NowPlayingRow(track: snapshot.current!),
          ),
        ],

        // ── Up Next (user queue — always expanded) ────────────────
        const SliverToBoxAdapter(child: _SectionHeader(title: 'Up Next')),
        if (snapshot.playNext.isEmpty)
          const SliverToBoxAdapter(
            child: _SectionPlaceholder(
              'Tap "Play Next" on a track to insert here.',
            ),
          )
        else
          SliverList.builder(
            itemCount: snapshot.playNext.length,
            itemBuilder: (_, i) => _MutableRow(
              track: snapshot.playNext[i],
              flatIndex: playNextStart + i,
              flatLen: flatLen,
              currentIndex: snapshot.currentIndex,
            ),
          ),

        // ── Slice 5: Radio seed header above Upcoming ────────────
        // SizedBox.shrink when no radio session — kept inside the
        // CustomScrollView so the layout doesn't churn on toggle.
        const SliverToBoxAdapter(child: RadioSeedHeader()),

        // ── Upcoming (context — collapsible) ──────────────────────
        SliverToBoxAdapter(
          child: _UpcomingHeader(
            count: snapshot.upcoming.length,
            expanded: upcomingExpanded,
            onToggle: onToggleUpcoming,
          ),
        ),
        if (snapshot.upcoming.isEmpty)
          const SliverToBoxAdapter(
            child: _SectionPlaceholder(
              'Empty — the contextual queue starts from a tap on Tracks.',
            ),
          )
        else if (upcomingExpanded)
          SliverList.builder(
            itemCount: snapshot.upcoming.length,
            itemBuilder: (_, i) => _MutableRow(
              track: snapshot.upcoming[i],
              flatIndex: upcomingStart + i,
              flatLen: flatLen,
              currentIndex: snapshot.currentIndex,
            ),
          ),

        SliverToBoxAdapter(
          child: SizedBox(
            height: Theme.of(context).extension<SpaceTokens>()!.s6,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s4 + 4, tokens.s4, tokens.s2),
      child: Text(
        title,
        style: scale.caption13.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Tappable header for the Upcoming (context) section.
///
/// Visually it's a [_SectionHeader] plus a "Playing from Tracks · N
/// tracks" attribution subtitle and a chevron indicating expand state.
/// Disabled / non-interactive when the upcoming zone is empty — there's
/// nothing to expand, and tapping a no-op is worse UX than a static
/// header.
///
/// Source attribution is hard-coded to "Tracks" in slice 1: that's the
/// only view that ever populates Upcoming (`TracksScreen` calls
/// `loadContext(allTracks, …)`). Slice 2 adds Album / Artist / Genre
/// detail screens, each of which will want its own attribution
/// string — at that point [QueueSnapshot] can grow a `contextLabel`
/// field and this widget reads from it.
class _UpcomingHeader extends StatelessWidget {
  const _UpcomingHeader({
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final hasContent = count > 0;
    return InkWell(
      onTap: hasContent ? onToggle : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s4 + 4, tokens.s4, tokens.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Upcoming',
                    style: scale.caption13.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (hasContent)
                    Padding(
                      padding: EdgeInsets.only(top: tokens.s1 / 2),
                      child: Text(
                        'Playing from Tracks · '
                        '$count ${count == 1 ? "track" : "tracks"}',
                        style: scale.caption13.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (hasContent)
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionPlaceholder extends StatelessWidget {
  const _SectionPlaceholder(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s2),
      child: Text(
        text,
        style: scale.body16.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(
        _displayTitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
      subtitle: _subtitleOf(track) == null
          ? null
          : Text(
              _subtitleOf(track)!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
    );
  }
}

class _NowPlayingRow extends StatelessWidget {
  const _NowPlayingRow({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.play_arrow, color: theme.colorScheme.primary),
      title: Text(
        _displayTitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: _subtitleOf(track) == null
          ? null
          : Text(
              _subtitleOf(track)!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.primary),
            ),
    );
  }
}

/// A row in [QueueZone.playNext] or [QueueZone.upcoming] — tap to
/// promote it to "next up" and skip, overflow menu to reorder or
/// remove.
class _MutableRow extends ConsumerWidget {
  const _MutableRow({
    required this.track,
    required this.flatIndex,
    required this.flatLen,
    required this.currentIndex,
  });

  final Track track;
  final int flatIndex;
  final int flatLen;
  final int currentIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Disable moves that QueueService.move() would no-op on:
    //   - Move up when the target slot is out of range or would
    //     collide with [currentIndex].
    //   - Move down when the target is out of range or collides.
    final moveUpTarget = flatIndex - 1;
    final moveDownTarget = flatIndex + 1;
    final canMoveUp = moveUpTarget >= 0 && moveUpTarget != currentIndex;
    final canMoveDown =
        moveDownTarget < flatLen && moveDownTarget != currentIndex;

    return ListTile(
      title: Text(
        _displayTitle(track),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitleOf(track) == null
          ? null
          : Text(
              _subtitleOf(track)!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: PopupMenuButton<_RowAction>(
        tooltip: 'Row actions',
        onSelected: (action) => _handleAction(ref, action),
        itemBuilder: (_) => <PopupMenuEntry<_RowAction>>[
          PopupMenuItem(
            value: _RowAction.moveUp,
            enabled: canMoveUp,
            child: const Text('Move up'),
          ),
          PopupMenuItem(
            value: _RowAction.moveDown,
            enabled: canMoveDown,
            child: const Text('Move down'),
          ),
          const PopupMenuItem(
            value: _RowAction.remove,
            child: Text('Remove'),
          ),
        ],
      ),
      onTap: () => _jumpToHere(ref),
    );
  }

  void _handleAction(WidgetRef ref, _RowAction action) {
    final notifier = ref.read(queueProvider.notifier);
    switch (action) {
      case _RowAction.moveUp:
        notifier.move(flatIndex, flatIndex - 1);
      case _RowAction.moveDown:
        notifier.move(flatIndex, flatIndex + 1);
      case _RowAction.remove:
        notifier.removeAt(flatIndex);
    }
  }

  /// Promotes this row to the slot right after [currentIndex] (so the
  /// next natural advance plays it), then skips forward. Handles the
  /// drained-queue edge case: with no current, we reseed the queue
  /// starting at [flatIndex] and call `play` directly — `skipToNext`
  /// is a no-op with a null current.
  void _jumpToHere(WidgetRef ref) {
    final snap = ref.read(queueProvider);
    final notifier = ref.read(queueProvider.notifier);
    final service = ref.read(playbackServiceProvider);

    if (snap.current == null) {
      // Drained queue — reseed starting here.
      notifier.loadContext(snap.flat, startIndex: flatIndex);
      // ignore: discarded_futures
      service.play();
      return;
    }

    final target = snap.currentIndex + 1;
    if (flatIndex != target) {
      notifier.move(flatIndex, target);
    }
    // ignore: discarded_futures
    service.skipToNext();
  }
}

enum _RowAction { moveUp, moveDown, remove }

class _EmptyQueueView extends StatelessWidget {
  const _EmptyQueueView();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.s6),
        child: const Text(
          'The queue is empty.\n\n'
          'Tap a track on the Tracks tab to start a playback context, '
          'or long-press a track for "Play Next" / "Add to Queue".',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

String _displayTitle(Track t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final path = t.path;
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

String? _subtitleOf(Track t) {
  final artist = t.artist ?? t.albumArtist;
  final album = t.album;
  if (artist == null && album == null) return null;
  if (artist == null) return album;
  if (album == null) return artist;
  return '$artist — $album';
}
