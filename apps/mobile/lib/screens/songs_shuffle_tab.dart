import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_playlist_engine/playlist_engine.dart' show TrackSeed;
import 'package:prism_ui/ui.dart';

import '../providers/playback_providers.dart';
import '../providers/radio_providers.dart';
import '../providers/songs_shuffle_providers.dart';
import '../widgets/mood_chip_row.dart';
import 'radio_context_sheet.dart';

/// Slice 10 §2.2 + slice-11 §B2 — Library → Songs is the iPod-shuffle
/// surface. The mood chip row is multi-select again: tapping a chip
/// toggles it in/out of the deck filter. Selected chips constrain the
/// `VibeShuffleQuery` eligible set under both True-Shuffle and Tempo
/// modes (the slice-10b D bypass bug is fixed in
/// `vibe_shuffle_query.dart` — True-Shuffle randomises *order*, not the
/// *eligible set*).
///
/// Top: big Shuffle Play CTA + True Shuffle + Infinite toggles.
/// Middle: "Pick a vibe" header + multi-select chip row (dimmed when
/// True Shuffle is on, as a visual hint that scoring is bypassed but
/// the filter still applies) + tempo dropdown.
/// Bottom: live deck list. Tap a row to play from there; the rest of
/// the visible deck loads as the queue tail. Long-press a row → the
/// 3-tile RadioContextSheet (Play Next / Add to Queue / Start Radio).
class SongsShuffleTab extends ConsumerStatefulWidget {
  const SongsShuffleTab({super.key});

  @override
  ConsumerState<SongsShuffleTab> createState() => _SongsShuffleTabState();
}

class _SongsShuffleTabState extends ConsumerState<SongsShuffleTab> {
  /// Threshold below which Infinite triggers a radio start. Matches
  /// spec §2.3 ("when ~10 tracks remain").
  static const int _lookaheadThreshold = 10;

  /// Set once we've fired startFromTrack so a flapping queue depth
  /// doesn't spam the notifier. Reset when Infinite toggles off, so
  /// re-enabling triggers a fresh start.
  bool _radioRequested = false;

  @override
  void initState() {
    super.initState();
    // Defer until after the first frame so ref.listenManual can attach.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listenManual<QueueSnapshot>(queueProvider, (prev, next) {
        final state = ref.read(songsShuffleStateProvider);
        if (!state.infinite) {
          _radioRequested = false; // toggle off resets the latch
          return;
        }
        final session = ref.read(radioSessionProvider);
        if (session != null) return; // already running
        final remaining = (next.current == null ? 0 : 1) +
            next.playNext.length +
            next.upcoming.length;
        if (remaining > _lookaheadThreshold) {
          _radioRequested = false;
          return;
        }
        if (_radioRequested) return;
        // Find the most-recently-played track; prefer current, else
        // the last in history.
        final seed = next.current ??
            (next.history.isEmpty ? null : next.history.last);
        if (seed == null) return;
        _radioRequested = true;
        // Show a one-shot toast on first activation per session
        // (spec §7 risk 4). _radioRequested already implements the
        // one-shot semantic — the toast fires once per re-entry into
        // the >threshold → ≤threshold transition.
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          const SnackBar(
            content: Text(
              'Infinite radio on — pulling more after this deck.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
        // ignore: discarded_futures
        ref.read(radioSessionProvider.notifier).startFromTrack(seed);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final state = ref.watch(songsShuffleStateProvider);
    final deckAsync = ref.watch(shuffleDeckProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Shuffle CTA + toggles row.
        Padding(
          padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s4, tokens.s2),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () =>
                      _shufflePlay(ref, deckAsync.asData?.value ?? const []),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle play'),
                ),
              ),
              SizedBox(width: tokens.s3),
              FilterChip(
                key: const Key('songs.trueShuffleToggle'),
                label: const Text('True Shuffle'),
                selected: state.trueShuffle,
                onSelected: (v) => ref
                    .read(songsShuffleStateProvider.notifier)
                    .setTrueShuffle(v),
              ),
              SizedBox(width: tokens.s2),
              FilterChip(
                key: const Key('songs.infiniteToggle'),
                label: const Text('Infinite'),
                avatar: const Icon(Icons.all_inclusive, size: 18),
                selected: state.infinite,
                onSelected: (v) => ref
                    .read(songsShuffleStateProvider.notifier)
                    .setInfinite(v),
              ),
            ],
          ),
        ),
        // Slice-11 §B2 — "Pick a vibe" header + multi-select chip row.
        // Tapping a chip toggles it in/out of `state.chips`; the deck
        // below reflows live. `dim: state.trueShuffle` is a visual hint
        // that True-Shuffle randomises ordering — the chip filter still
        // applies (slice-10b D bypass bug fixed in
        // VibeShuffleQuery.run).
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1),
          child: Text(
            'Pick a vibe',
            style: scale.caption13.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        MoodChipRow(
          controller: MoodChipController.multi(
            initial: state.chips,
            onChanged: (chips) =>
                ref.read(songsShuffleStateProvider.notifier).setChips(chips),
          ),
          dim: state.trueShuffle,
        ),
        // Tempo dropdown row.
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _TempoDropdown(
              value: state.band,
              onChanged: (b) =>
                  ref.read(songsShuffleStateProvider.notifier).setBand(b),
            ),
          ),
        ),
        const Divider(height: 1),
        // Deck count + list.
        deckAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: EdgeInsets.all(tokens.s4),
            child: Text(
              'Shuffle query failed: $e',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          data: (deck) {
            if (deck.isEmpty) {
              return Padding(
                padding: EdgeInsets.all(tokens.s6),
                child: Center(
                  child: Text(
                    'No tracks match — try a different tempo or '
                    'turn on True Shuffle.',
                    style: scale.body16,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.fromLTRB(
                  tokens.s4, tokens.s2, tokens.s4, tokens.s1),
              child: Text(
                'Showing ${deck.length} tracks',
                style: scale.caption13.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            );
          },
        ),
        Expanded(
          child: deckAsync.maybeWhen(
            orElse: () => const SizedBox.shrink(),
            data: (deck) => ListView.builder(
              itemCount: deck.length,
              itemBuilder: (context, i) {
                final t = deck[i];
                return ListTile(
                  title: Text(
                    t.title ?? _basename(t.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [t.artist, t.album]
                        .whereType<String>()
                        .where((s) => s.isNotEmpty)
                        .join(' — '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: t.bpm != null
                      ? Text('${t.bpm!.toStringAsFixed(0)} bpm')
                      : null,
                  onTap: () => _playFromIndex(ref, deck, i),
                  // Slice-10b: long-press a deck row to start radio
                  // from that track. ShuffleTrack already carries the
                  // engine `trackId`; no pathToId hop needed.
                  onLongPress: () => _openRadioSheetForDeckRow(context, t),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _shufflePlay(WidgetRef ref, List<ShuffleTrack> deck) {
    if (deck.isEmpty) return;
    // Convert ShuffleTrack to Track via the deck's tag fields. Each
    // ShuffleTrack carries the path verbatim, which is the queue
    // service's identity key.
    final tracks = [
      for (final t in deck)
        Track(
          path: t.path,
          mtimeMs: 0,
          title: t.title,
          artist: t.artist,
          album: t.album,
        ),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: 0);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  void _playFromIndex(WidgetRef ref, List<ShuffleTrack> deck, int i) {
    if (deck.isEmpty) return;
    final tracks = [
      for (final t in deck)
        Track(
          path: t.path,
          mtimeMs: 0,
          title: t.title,
          artist: t.artist,
          album: t.album,
        ),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: i);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  /// Slice-10b: long-press a deck row → open the radio context sheet
  /// seeded from that track. [ShuffleTrack] already carries the cache
  /// `trackId` (slice-4 invariant), so we skip the `pathToIdProvider`
  /// hop the album/playlist/artist surfaces use.
  Future<void> _openRadioSheetForDeckRow(
    BuildContext context,
    ShuffleTrack t,
  ) async {
    if (!context.mounted) return;
    await RadioContextSheet.show(
      context,
      TrackSeed(
        trackId: t.trackId,
        title: t.title ?? _basename(t.path),
      ),
    );
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    final base = i < 0 ? path : path.substring(i + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

class _TempoDropdown extends StatelessWidget {
  const _TempoDropdown({required this.value, required this.onChanged});
  final TempoBand? value;
  final ValueChanged<TempoBand?> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<TempoBand?>(
      tooltip: 'Tempo',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => const [
        PopupMenuItem<TempoBand?>(value: null, child: Text('Any tempo')),
        PopupMenuItem<TempoBand?>(
            value: TempoBand.calm, child: Text('Calm (<90)')),
        PopupMenuItem<TempoBand?>(
            value: TempoBand.mid, child: Text('Mid (90–120)')),
        PopupMenuItem<TempoBand?>(
            value: TempoBand.hot, child: Text('Hot (>120)')),
      ],
      child: Chip(
        avatar: const Icon(Icons.speed_outlined, size: 18),
        label: Text(_label(value)),
      ),
    );
  }

  static String _label(TempoBand? band) {
    switch (band) {
      case null:
        return 'Any tempo';
      case TempoBand.calm:
        return 'Calm';
      case TempoBand.mid:
        return 'Mid';
      case TempoBand.hot:
        return 'Hot';
    }
  }
}
