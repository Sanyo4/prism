import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart' hide KnnHit;
// Track A's barrel re-exports the slice-6 types; the secondary
// import on `playlist_result.dart` is now redundant.
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:prism_ui/ui.dart';

import '../providers/ai_compose_playback_providers.dart';
import '../providers/playback_providers.dart';
import '../providers/playlist_engine_providers.dart';
import '../providers/radio_providers.dart' show trackByIdLookupProvider;

/// Result surface — rendered inside the New Vibe sheet once
/// `PlaylistEngine.generate` resolves. Shows:
///
/// - The blurb in headline-italic style.
/// - 12 `ListTile` rows (track no, title, artist, duration). A
///   tap calls `QueueService.loadContext(tracks, startIndex: i)` and
///   begins playback at the tapped row.
/// - A bottom `FloatingActionButton.extended` "Play" that loads the
///   queue at index 0 and pops the sheet.
/// - A top-right "Generate again" `IconButton` that
///   `ref.invalidate(newVibeProvider(vibe))` to re-run the pipeline.
///
/// Track materialisation: `result.candidates` carries `CandidateMeta`
/// with title + artist already populated (per Track A's documented
/// shape), so the row label render is a pure read. Tap → play and
/// the FAB flow rely on `trackByIdLookupProvider` (slice 5's
/// `id → Track` map) to feed `QueueService.loadContext` real tracks
/// — slice-1's contract.
class PlaylistResultCard extends ConsumerWidget {
  const PlaylistResultCard({
    super.key,
    required this.result,
    required this.vibe,
    required this.onPlayed,
  });

  /// The pipeline's output — exactly `length` (default 12) ids.
  final PlaylistResult result;

  /// The vibe text used to identify the family-keyed notifier so
  /// the "Generate again" button can invalidate it.
  final String vibe;

  /// Called after the queue is loaded and `play()` fires. Sheet
  /// pops itself in this callback so widget tests can intercept.
  final VoidCallback onPlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final candidates = result.candidates;
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s4, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      result.blurb,
                      style: scale.display20.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Generate again',
                    icon: const Icon(Icons.refresh),
                    onPressed: () =>
                        ref.invalidate(newVibeProvider(vibe)),
                  ),
                ],
              ),
              SizedBox(height: tokens.s2),
              Expanded(
                child: ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (context, i) {
                    final meta = candidates[i];
                    return _Row(
                      meta: meta,
                      number: i + 1,
                      onTap: () => _playFrom(ref, i),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: tokens.s4,
          bottom: tokens.s4,
          child: FloatingActionButton.extended(
            onPressed: () {
              _playFrom(ref, 0);
              onPlayed();
            },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
          ),
        ),
      ],
    );
  }

  void _playFrom(WidgetRef ref, int startIndex) {
    final lookup = ref.read(trackByIdLookupProvider);
    final tracks = <Track>[];
    for (final id in result.trackIds) {
      final t = lookup(id);
      if (t != null) tracks.add(t);
    }
    if (tracks.isEmpty) return;
    final clampedStart =
        startIndex.clamp(0, tracks.length - 1);
    ref
        .read(queueProvider.notifier)
        .loadContext(tracks, startIndex: clampedStart);
    // ignore: discarded_futures — fire-and-forget; errors surface
    // via the player state stream to NowPlayingScreen.
    ref.read(playbackServiceProvider).play();
    // Slice-10 — register the AI Compose playback so the end-of-queue
    // observer can surface the "Keep playing" sheet when this playlist
    // drains. We record the live Track list (already mapped via
    // trackByIdLookupProvider above) plus the originating vibe prompt
    // and the LLM blurb for the sheet's display label.
    ref.read(aiComposePlaybackProvider.notifier).set(
          AiComposePlayback(
            tracks: tracks,
            prompt: vibe,
            label: result.blurb,
          ),
        );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.meta,
    required this.number,
    required this.onTap,
  });

  final CandidateMeta meta;
  final int number;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = theme.extension<TypographyScale>()!;
    return ListTile(
      leading: SizedBox(
        width: 24,
        child: Text(
          number.toString(),
          textAlign: TextAlign.right,
          style: scale.body16.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Text(
        meta.title.isEmpty ? 'Track ${meta.trackId}' : meta.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: scale.body16,
      ),
      subtitle: Text(
        meta.artistKey,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: scale.caption13,
      ),
      trailing: meta.bpm > 0
          ? Text(
              '${meta.bpm.toStringAsFixed(0)} bpm',
              style: scale.caption13.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}
