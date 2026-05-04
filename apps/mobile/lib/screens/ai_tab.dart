import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/playlists_provider.dart';
import '../shell/app_shell.dart';
import '../widgets/compose_card.dart';
import 'new_vibe.dart';
import 'playlist_detail_screen.dart';

/// Create (AI) tab — slice-10b §C4.
///
/// Layout (top → bottom):
/// 1. "Create" display header.
/// 2. [ComposeCard] — shared hero card extracted from Home.
/// 3. "Try a prompt" caption + 2-col grid of 6 prompt-suggestion tiles.
///    Tapping a tile pushes [NewVibeSheet] with the prompt pre-filled.
/// 4. "Recent generations" caption + horizontal strip of up to 5
///    persisted [PlaylistRecord]s — only shown when the provider has
///    data and the list is non-empty.
class AiTabScreen extends ConsumerWidget {
  const AiTabScreen({super.key});

  /// Same as [AppShell.aiRoute] — re-exported here so callers don't
  /// have to import the shell just to push the AI surface.
  static const String routeName = '/ai';

  static const _promptSuggestions = <String>[
    'Rainy Sunday jazz',
    'Late-night drive',
    'Workout pump',
    'Sad coffee',
    'Sunday brunch',
    'Focus deep work',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final playlistsAsync = ref.watch(playlistsProvider);

    return AppShell(
      title: 'AI',
      currentTab: AppTab.ai,
      // Slice 7 §13 — AI tab uses the lilac-leaning AuroraVariant.ai.
      useAurora: AuroraVariant.ai,
      showAppBar: false,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.s4,
          tokens.s4,
          tokens.s4,
          tokens.s8,
        ),
        children: [
          // "Create" display header — mirrors the Home greeting block
          // in visual weight and position.
          Padding(
            padding: EdgeInsets.only(bottom: tokens.s4, left: tokens.s2),
            child: Text(
              'Create',
              style: scale.display36.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.8,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),

          // 1. Compose hero.
          const ComposeCard(),
          SizedBox(height: tokens.s6),

          // 2. "Try a prompt" caption.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.s2),
            child: Text('Try a prompt', style: scale.display20),
          ),
          SizedBox(height: tokens.s3),

          // 3. 2-col grid of 6 prompt-suggestion tiles.
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: tokens.s3,
            crossAxisSpacing: tokens.s3,
            childAspectRatio: 2.4,
            children: [
              for (final prompt in _promptSuggestions)
                _PromptTile(prompt: prompt),
            ],
          ),

          // 4 + 5. Recent generations strip (conditional on data).
          ...playlistsAsync.maybeWhen(
            data: (playlists) {
              if (playlists.isEmpty) return const <Widget>[];
              final recent = playlists.take(5).toList();
              return <Widget>[
                SizedBox(height: tokens.s6),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: tokens.s2),
                  child: Text('Recent generations', style: scale.display20),
                ),
                SizedBox(height: tokens.s3),
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: recent.length,
                    separatorBuilder: (_, _) => SizedBox(width: tokens.s3),
                    itemBuilder: (_, i) =>
                        _RecentPlaylistCard(playlist: recent[i]),
                  ),
                ),
              ];
            },
            orElse: () => const <Widget>[],
          ),
        ],
      ),
    );
  }
}

class _PromptTile extends StatelessWidget {
  const _PromptTile({required this.prompt});
  final String prompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return InkWell(
      borderRadius: BorderRadius.circular(tokens.s3),
      onTap: () => Navigator.of(context).pushNamed(
        NewVibeSheet.routeName,
        arguments: prompt,
      ),
      child: Glass(
        intensity: GlassIntensity.light,
        radius: tokens.s3,
        padding: EdgeInsets.all(tokens.s4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                prompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: scale.body16.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            Icon(
              Icons.arrow_forward,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentPlaylistCard extends ConsumerWidget {
  const _RecentPlaylistCard({required this.playlist});
  final PlaylistRecord playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return SizedBox(
      width: 220,
      child: InkWell(
        borderRadius: BorderRadius.circular(tokens.s3),
        onTap: () => Navigator.of(context).push(
          PlaylistDetailScreen.route(playlist.id),
        ),
        child: Glass(
          intensity: GlassIntensity.light,
          radius: tokens.s3,
          padding: EdgeInsets.all(tokens.s3),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.auto_awesome,
                  color: theme.colorScheme.primary,
                ),
              ),
              SizedBox(width: tokens.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      playlist.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: scale.body16.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${playlist.trackCount} tracks',
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
  }
}
