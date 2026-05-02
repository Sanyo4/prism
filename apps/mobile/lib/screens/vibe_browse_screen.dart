import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import '../providers/ingest_providers.dart';
import '../providers/playback_providers.dart';
import '../widgets/tempo_band_chips.dart';

/// Vibe browse — the Library "Vibe" tab. Hosts five classifier-native
/// chips above a tempo-band segmented control, plus a live-updating
/// list. The mood and band selections are local to this widget; we
/// don't persist them across navigations because Vibe is a
/// crate-digging surface, not a state to remember.
class VibeBrowseScreen extends ConsumerStatefulWidget {
  const VibeBrowseScreen({super.key});

  @override
  ConsumerState<VibeBrowseScreen> createState() => _VibeBrowseScreenState();
}

class _VibeBrowseScreenState extends ConsumerState<VibeBrowseScreen> {
  VibeMoodChip _mood = VibeMoodChip.relaxed;
  TempoBand? _band; // null == "Off"

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(vibeResultsProvider(
      (mood: _mood, band: _band),
    ));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: VibeMoodChip.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final chip = VibeMoodChip.values[i];
                return FilterChip(
                  label: Text(_label(chip)),
                  selected: _mood == chip,
                  avatar: Icon(_iconFor(chip), size: 18),
                  onSelected: (s) {
                    if (s) setState(() => _mood = chip);
                  },
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Center(
            child: TempoBandChips(
              selected: _band,
              onChanged: (b) => setState(() => _band = b),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Vibe query failed: $e')),
            data: (rows) => rows.isEmpty
                ? const _EmptyState()
                : _ResultsList(rows: rows),
          ),
        ),
      ],
    );
  }

  static String _label(VibeMoodChip chip) {
    switch (chip) {
      case VibeMoodChip.happy:
        return 'Happy';
      case VibeMoodChip.sad:
        return 'Sad';
      case VibeMoodChip.aggressive:
        return 'Aggressive';
      case VibeMoodChip.relaxed:
        return 'Relaxed';
      case VibeMoodChip.party:
        return 'Party';
    }
  }

  static IconData _iconFor(VibeMoodChip chip) {
    switch (chip) {
      case VibeMoodChip.happy:
        return Icons.sentiment_very_satisfied_outlined;
      case VibeMoodChip.sad:
        return Icons.sentiment_dissatisfied_outlined;
      case VibeMoodChip.aggressive:
        return Icons.bolt_outlined;
      case VibeMoodChip.relaxed:
        return Icons.spa_outlined;
      case VibeMoodChip.party:
        return Icons.celebration_outlined;
    }
  }
}

class _ResultsList extends ConsumerWidget {
  const _ResultsList({required this.rows});
  final List<VibeTrack> rows;

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
          trailing: Text('${r.bpm?.toStringAsFixed(0) ?? "—"} bpm'),
          onTap: () => _playFrom(ref, i),
        );
      },
    );
  }

  void _playFrom(WidgetRef ref, int index) {
    final tracks = [
      for (final r in rows)
        Track(
          path: r.path,
          mtimeMs: 0,
          title: r.title,
          artist: r.artist,
          album: r.album,
        ),
    ];
    ref.read(queueProvider.notifier).loadContext(tracks, startIndex: index);
    // ignore: discarded_futures
    ref.read(playbackServiceProvider).play();
  }

  static String _subtitleOf(VibeTrack r) {
    final parts = <String>[];
    if (r.artist != null && r.artist!.isNotEmpty) parts.add(r.artist!);
    if (r.album != null && r.album!.isNotEmpty) parts.add(r.album!);
    return parts.isEmpty ? r.path : parts.join(' — ');
  }

  static String _basenameOf(String path) {
    final slash = path.lastIndexOf('/');
    final base = slash < 0 ? path : path.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_outlined,
                size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'Nothing in this vibe yet.',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Try a different mood or tempo, or Re-scan after running the desktop indexer.',
              style: theme.textTheme.bodyMedium?.copyWith(
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
