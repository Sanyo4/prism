import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/metadata_providers.dart';
import 'settings_sections.dart';

/// Settings → "Online Metadata" section. Three controls:
///
/// 1. `enabled` toggle — gates all MusicBrainz/CAA traffic. Off →
///    `MetadataRepository.configured == false` and BackfillQueue
///    short-circuits.
/// 2. Contact email — the value MusicBrainz embeds in `User-Agent`.
///    Required when `enabled == true`; an empty email surfaces the
///    fail-closed banner described in §10.
/// 3. Clear metadata cache — wipes both `metadata_cache` and
///    `track_meta` in one transaction (`MetadataDao.clearAll`).
///
/// We keep the (optional) Last.fm API key on this section too even
/// though the slice plan §1 didn't surface it explicitly — without a
/// place to enter it, slice 2's verification 8 ("artist with a known
/// MBID") can't be exercised, and the field is a one-line addition.
class SettingsOnlineMetadataSection extends ConsumerWidget {
  const SettingsOnlineMetadataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final settings = ref.watch(onlineMetadataSettingsProvider);
    final notifier = ref.read(onlineMetadataSettingsProvider.notifier);
    final emailMissing =
        settings.contactEmail.trim().isEmpty && settings.enabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Online Metadata'),
        if (emailMissing)
          Material(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: EdgeInsets.all(tokens.s3),
              child: const Text(
                'Enter a contact email — MusicBrainz refuses anonymous '
                'traffic.',
              ),
            ),
          ),
        SwitchListTile(
          title: const Text('Enable online metadata'),
          subtitle: const Text(
              'Fill in missing tags + cover art via MusicBrainz, CAA, Last.fm.'),
          value: settings.enabled,
          onChanged: (v) => notifier.setEnabled(v),
        ),
        ListTile(
          title: const Text('Contact email'),
          subtitle: Text(settings.contactEmail.isEmpty
              ? 'Required by MusicBrainz to identify the app.'
              : settings.contactEmail),
          trailing: const Icon(Icons.edit),
          onTap: () => _editEmail(context, settings.contactEmail, notifier),
        ),
        ListTile(
          title: const Text('Last.fm API key (optional)'),
          subtitle: Text(
            (settings.lastfmApiKey?.isNotEmpty ?? false)
                ? '••••${settings.lastfmApiKey!.substring(settings.lastfmApiKey!.length.clamp(0, 4))}'
                : 'Without a key, artist bios are skipped.',
          ),
          trailing: const Icon(Icons.edit),
          onTap: () => _editLastfm(context, settings.lastfmApiKey, notifier),
        ),
        ListTile(
          leading: Icon(
            Icons.delete_sweep,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(
            'Clear metadata cache',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          subtitle: const Text('Wipes MusicBrainz + CAA + Last.fm cache rows.'),
          onTap: () => _confirmClear(context, ref),
        ),
      ],
    );
  }

  Future<void> _editEmail(
    BuildContext context,
    String current,
    OnlineMetadataSettingsNotifier notifier,
  ) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Contact email'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(hintText: 'you@example.com'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await notifier.setContactEmail(result);
    }
  }

  Future<void> _editLastfm(
    BuildContext context,
    String? current,
    OnlineMetadataSettingsNotifier notifier,
  ) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Last.fm API key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Optional'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              controller.text.trim().isEmpty ? null : controller.text.trim(),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    await notifier.setLastfmKey(result);
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear metadata cache?'),
        content: const Text(
          'Cached MB / CAA / Last.fm responses will be deleted. The next '
          'scan will re-fetch from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repoAsync = ref.read(metadataRepositoryProvider);
    final repo = repoAsync.asData?.value;
    if (repo == null) return;
    await repo.clearCache();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metadata cache cleared')),
      );
    }
  }
}
