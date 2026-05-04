/// Slice-10b §C1 — live progress card surfaced in the Settings →
/// Online Metadata section while [BackfillQueue.run] is active.
/// Auto-dismisses when no active run; otherwise renders a header,
/// linear progress bar, current track title, count, and a Cancel
/// action.
///
/// Mirrors the shape of `model_download_card.dart` (slice 8).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../backfill/backfill_queue.dart';
import '../providers/metadata_providers.dart';

/// Live progress card for Settings → Online Metadata.
///
/// Returns [SizedBox.shrink] when no backfill run is active so it
/// adds no visual weight when idle.
class BackfillProgressCard extends ConsumerWidget {
  const BackfillProgressCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final progressAsync = ref.watch(backfillProgressProvider);
    final progress = progressAsync.asData?.value;
    if (progress == null) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.s4,
        vertical: tokens.s2,
      ),
      child: Glass(
        intensity: GlassIntensity.medium,
        radius: tokens.s3,
        padding: EdgeInsets.all(tokens.s4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  progress.isDone
                      ? Icons.check_circle
                      : Icons.cloud_download_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                SizedBox(width: tokens.s2),
                Expanded(
                  child: Text(
                    progress.isDone ? 'Metadata updated' : 'Online metadata',
                    style: scale.body16.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!progress.isDone)
                  TextButton(
                    onPressed: () {
                      // ignore: discarded_futures
                      ref.read(backfillQueueProvider)?.stop();
                    },
                    child: const Text('Cancel'),
                  ),
              ],
            ),
            SizedBox(height: tokens.s2),
            ClipRRect(
              borderRadius: BorderRadius.circular(tokens.s1),
              child: LinearProgressIndicator(
                value: progress.fraction.clamp(0.0, 1.0),
                minHeight: 6,
              ),
            ),
            SizedBox(height: tokens.s2),
            if (progress.currentTrackTitle != null)
              Text(
                'Enriching: ${progress.currentTrackTitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: scale.caption13.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Text(
              '${progress.processed} / ${progress.total} tracks',
              style: scale.caption13.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
