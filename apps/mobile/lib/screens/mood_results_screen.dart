import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/ingest_providers.dart';
import '../providers/playback_providers.dart';
import '../widgets/mood_chip_row.dart';

/// Filtered + ranked list for one [MoodChip]. Pushed onto the
/// navigator from `MoodChipRow`'s tap.
class MoodResultsScreen extends ConsumerWidget {
  const MoodResultsScreen({super.key, required this.chip});

  final MoodChip chip;

  static Route<void> route(MoodChip chip) =>
      MaterialPageRoute(builder: (_) => MoodResultsScreen(chip: chip));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(moodResultsProvider(chip));
    return Scaffold(
      appBar: AppBar(title: Text(_titleFor(chip))),
      body: results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Mood query failed: $e')),
        data: (rows) => rows.isEmpty
            ? _EmptyState(chip: chip)
            : _RankedList(chip: chip, rows: rows),
      ),
    );
  }

  static String _titleFor(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return 'Happy';
      case MoodChip.sad:
        return 'Sad';
      case MoodChip.chill:
        return 'Chill';
      case MoodChip.energetic:
        return 'Energetic';
      case MoodChip.focus:
        return 'Focus';
    }
  }
}

class _RankedList extends ConsumerWidget {
  const _RankedList({required this.chip, required this.rows});
  final MoodChip chip;
  final List<RankedTrack> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final r = rows[i];
        return ListTile(
          title: Text(
            r.title ?? _basenameOf(r.path),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _subtitleOf(r),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(_confidenceLabel(r.moodConfidence)),
          onTap: () => _playFrom(ref, i),
        );
      },
    );
  }

  void _playFrom(WidgetRef ref, int index) {
    // Mood results don't carry full Track metadata — we degrade to a
    // path-only synthetic Track and let the queue + playback service
    // resolve tags lazily from the audio file. PlaybackService still
    // applies measured RG from the cache via the path-keyed lookup.
    final tracks = [
      for (final r in rows)
        Track(path: r.path, mtimeMs: 0, title: r.title, artist: r.artist, album: r.album),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: index);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  static String _subtitleOf(RankedTrack r) {
    final parts = <String>[];
    if (r.artist != null && r.artist!.isNotEmpty) parts.add(r.artist!);
    if (r.album != null && r.album!.isNotEmpty) parts.add(r.album!);
    if (parts.isEmpty) parts.add(r.path);
    return parts.join(' — ');
  }

  static String _confidenceLabel(double v) {
    final pct = (v.clamp(0.0, 1.0) * 100).round();
    return '$pct%';
  }

  static String _basenameOf(String path) {
    final slash = path.lastIndexOf('/');
    final base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.chip});
  final MoodChip chip;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              MoodChipRow.visualOrder.contains(chip)
                  ? Icons.queue_music_outlined
                  : Icons.help_outline,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            SizedBox(height: tokens.s4),
            Text(
              'Nothing matches "${MoodResultsScreen._titleFor(chip)}" yet.',
              style: scale.display20,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: tokens.s2),
            Text(
              'Run the desktop indexer on your library and Re-scan from Settings to populate the cache.',
              style: scale.body16.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
