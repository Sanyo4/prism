import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/playback_providers.dart';
import '../providers/songs_shuffle_providers.dart';
import '../widgets/mood_chip_row.dart';

/// Slice 10 §2.2 — Library → Songs is now the iPod-shuffle surface.
/// Top: big Shuffle Play CTA + True Shuffle + Infinite toggles.
/// Middle: multi-select mood chip row + tempo dropdown.
/// Bottom: live deck list. Tap a row to play from there; the rest of
/// the visible deck loads as the queue tail.
class SongsShuffleTab extends ConsumerWidget {
  const SongsShuffleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        // "Steer by vibe" header + multi-select chip row.
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1),
          child: Text(
            'Steer by vibe',
            style: scale.caption13.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        MoodChipRow(
          dim: state.trueShuffle,
          controller: MoodChipController.multi(
            initial: state.chips,
            onChanged: (next) =>
                ref.read(songsShuffleStateProvider.notifier).setChips(next),
          ),
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
                    'No tracks match — pick fewer chips or try True Shuffle.',
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
