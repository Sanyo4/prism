import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/ai_compose_playback_providers.dart';
import '../providers/radio_providers.dart';

/// Slice 10 §2.3 — end-of-playlist sheet. Shown when an AI Compose
/// playlist drains. Primary action calls `startFromCluster` with the
/// playlist's tracks + the original prompt as the steering hint.
class EndOfPlaylistSheet extends ConsumerWidget {
  const EndOfPlaylistSheet({super.key, required this.playback});

  final AiComposePlayback playback;

  static Future<void> show(BuildContext context, AiComposePlayback playback) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => EndOfPlaylistSheet(playback: playback),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(tokens.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Done with this set.', style: scale.display20),
            SizedBox(height: tokens.s2),
            Text(
              'Keep going? Prism will pick more like "${playback.prompt}".',
              style: scale.body16.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: tokens.s4),
            FilledButton.icon(
              onPressed: () async {
                await ref
                    .read(radioSessionProvider.notifier)
                    .startFromCluster(
                      playback.tracks,
                      steeringHint: playback.prompt,
                    );
                ref.read(aiComposePlaybackProvider.notifier).clear();
                if (context.mounted) Navigator.of(context).pop();
              },
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Keep playing'),
            ),
            SizedBox(height: tokens.s2),
            TextButton(
              onPressed: () {
                ref.read(aiComposePlaybackProvider.notifier).clear();
                Navigator.of(context).pop();
              },
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
