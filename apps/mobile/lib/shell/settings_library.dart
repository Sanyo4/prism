import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import '../providers/cache_db_providers.dart';
import '../providers/ingest_providers.dart';
import 'settings_sections.dart';

/// Slice-4 Library section: Re-scan trigger + cache stats. Lives in
/// the shell directory so the rest of `screens/` isn't peppered with
/// settings-only widgets.
class SettingsLibrarySection extends ConsumerWidget {
  const SettingsLibrarySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(ingestControllerProvider);
    final stats = ref.watch(cacheStatsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Library'),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('Re-scan library'),
          subtitle: ui.running
              ? Text('Scanning… ${ui.processed} files seen')
              : ui.error != null
                  ? Text('Last run failed: ${ui.error}')
                  : ui.lastSummary == null
                      ? const Text('Tap to walk the library and re-ingest sidecars.')
                      : Text(_lastSummary(ui.lastSummary!)),
          trailing: ui.running
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: ui.running
              ? null
              : () =>
                  ref.read(ingestControllerProvider.notifier).rescan(),
        ),
        if (Vec0Loader.loadFailed)
          ListTile(
            leading: Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: const Text('Embeddings disabled — radio unavailable on this device'),
            subtitle: Text(
              (Vec0Loader.loadFailureMessage ?? '').length > 120
                  ? '${(Vec0Loader.loadFailureMessage ?? '').substring(0, 120)}…'
                  : (Vec0Loader.loadFailureMessage ?? ''),
            ),
          ),
        stats.when(
          loading: () => const ListTile(
            leading: Icon(Icons.analytics_outlined),
            title: Text('Cache stats'),
            subtitle: Text('Loading…'),
          ),
          error: (e, _) => ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Cache stats'),
            subtitle: Text('Error: $e'),
          ),
          data: (s) => ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Cache stats'),
            subtitle: Text(_renderStats(s)),
          ),
        ),
      ],
    );
  }

  static String _lastSummary(IngestSummary s) {
    return 'ready=${s.ready}  '
        'pending=${s.analysisPending}  '
        'missing=${s.missingAudio}';
  }

  static String _renderStats(CacheStats s) {
    return 'ready=${s.ready}  '
        'pending=${s.analysisPending}  '
        'missing=${s.missingAudio}  '
        'embeddings=${s.embeddings}';
  }
}
