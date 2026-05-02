import 'package:flutter/material.dart';

import 'settings_online_metadata.dart';
import 'settings_sections.dart';

/// Settings surface. Slice 1 had two placeholder sections; slice 2
/// composes [SettingsOnlineMetadataSection] in front of the
/// placeholders. Other sections (Library re-scan path, Playback
/// ReplayGain toggle) remain placeholders until later slices wire
/// them.
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
          SettingsSectionHeader(title: 'Library'),
          SettingsSectionPlaceholder(
            subtitle:
                'Scan path, re-scan, and clear cache — slice 4 wires these up.',
          ),
          SettingsSectionHeader(title: 'Playback'),
          SettingsSectionPlaceholder(
            subtitle:
                'ReplayGain toggle and gapless defaults — slice 4 wires these up.',
          ),
        ],
      ),
    );
  }
}
