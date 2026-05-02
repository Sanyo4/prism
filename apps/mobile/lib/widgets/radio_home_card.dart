import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/radio_providers.dart';
import '../radio/recent_seeds_store.dart';

/// Home-screen "Radio" row showing up to three recent seeds (LRU).
///
/// Renders a placeholder card when no seeds have ever been started;
/// when seeds exist, paginates through them in a horizontal
/// [PageView]. Tapping a card boots a fresh radio session via
/// `RadioSessionNotifier.startFrom*`, mirroring the long-press sheet
/// flow but addressed by the persisted seed ref instead of a fresh
/// long-press.
///
/// Per slice 5 §10 risk 12, [RecentSeedsStore] is the user's one-tap
/// restore after an OEM low-memory purge — this card is the surface
/// where that recovery happens.
class RadioHomeCard extends ConsumerWidget {
  const RadioHomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seeds = ref.watch(recentSeedsProvider);
    final theme = Theme.of(context);

    if (seeds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.radio_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Long-press a track, album, or artist to start radio.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 96,
      child: PageView.builder(
        controller: PageController(viewportFraction: 0.86),
        itemCount: seeds.length,
        itemBuilder: (context, i) {
          final entry = seeds[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _launch(ref, entry),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.radio_outlined,
                        color: theme.colorScheme.primary,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Radio',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              entry.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _kindLabel(entry.kind),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _launch(WidgetRef ref, RecentSeedEntry entry) async {
    final notifier = ref.read(radioSessionProvider.notifier);
    switch (entry.kind) {
      case 'track':
        // Track-id seeds need an actual `Track` row to call into
        // `startFromTrack`. We resolve it through the live lookup —
        // when the row is gone (file removed since the seed was
        // saved), there's nothing to do; the user re-seeds via long-
        // press.
        final id = int.tryParse(entry.ref);
        if (id == null) return;
        final lookup = ref.read(trackByIdLookupProvider);
        final track = lookup(id);
        if (track == null) return;
        await notifier.startFromTrack(track);
      case 'album':
        await notifier.startFromAlbum(
          albumKey: entry.ref,
          title: entry.label,
        );
      case 'artist':
        await notifier.startFromArtist(
          artist: entry.ref,
          label: entry.label,
        );
    }
  }

  static String _kindLabel(String kind) {
    switch (kind) {
      case 'track':
        return 'From a track';
      case 'album':
        return 'From an album';
      case 'artist':
        return 'From an artist';
      default:
        return kind;
    }
  }
}
