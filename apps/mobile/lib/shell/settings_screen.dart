import 'package:flutter/material.dart';

import 'settings_library.dart';
import 'settings_online_metadata.dart';
import 'settings_sections.dart';

/// Settings surface. Slice-1 placeholders → slice-2 metadata section →
/// slice-4 library re-scan + cache stats. Playback section remains
/// placeholder until a later slice surfaces the RG toggle.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Canonical push for the gear icon. Kept static so callers don't
  /// have to reach into a route-name string and miss the fact that
  /// this screen isn't a bottom-nav tab — it's a pushed detail route.
  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: const [
          SettingsOnlineMetadataSection(),
          SettingsLibrarySection(),
          SettingsSectionHeader(title: 'Playback'),
          SettingsSectionPlaceholder(
            subtitle:
                'ReplayGain toggle and gapless defaults — wired in a later slice.',
          ),
        ],
      ),
    );
  }
}
