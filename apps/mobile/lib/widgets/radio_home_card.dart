import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

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
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;

    if (seeds.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s4, tokens.s1),
        child: Glass(
          intensity: GlassIntensity.medium,
          radius: tokens.s4,
          padding: EdgeInsets.all(tokens.s4),
          child: Row(
            children: [
              Icon(
                Icons.radio_outlined,
                color: theme.colorScheme.primary,
              ),
              SizedBox(width: tokens.s3),
              Expanded(
                child: Text(
                  'Long-press a track, album, or artist to start radio.',
                  style: scale.body16,
                ),
              ),
            ],
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
            padding: EdgeInsets.symmetric(horizontal: tokens.s2, vertical: tokens.s2),
            child: Glass(
              intensity: GlassIntensity.medium,
              radius: tokens.s4,
              padding: EdgeInsets.all(tokens.s3),
              child: InkWell(
                onTap: () => _launch(ref, entry),
                child: Row(
                  children: [
                    Icon(
                      Icons.radio_outlined,
                      color: theme.colorScheme.primary,
                      size: 32,
                    ),
                    SizedBox(width: tokens.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Radio',
                            style: scale.caption13.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                          SizedBox(height: tokens.s1 / 2),
                          Text(
                            entry.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: scale.display20,
                          ),
                          SizedBox(height: tokens.s1 / 2),
                          Text(
                            _kindLabel(entry.kind),
                            style: scale.caption13.copyWith(
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
