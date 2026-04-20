import 'package:flutter/material.dart';

import 'settings_sections.dart';

/// Placeholder Settings surface.
///
/// Slice 1's only contract here is: the gear icon in [AppShell] reaches
/// this screen from every top-level tab, and the screen renders two
/// slice-tagged placeholder sections (`Library`, `Playback`). Later
/// slices (2, 4, 7) append real rows under those headers without
/// restructuring — which is why the header + subtitle widgets live in
/// a separate `settings_sections.dart` file.
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
          SettingsSectionHeader(title: 'Library'),
          SettingsSectionPlaceholder(
            subtitle:
                'Scan path, re-scan, and clear cache — slice 2 wires these up.',
          ),
          SettingsSectionHeader(title: 'Playback'),
          SettingsSectionPlaceholder(
            subtitle:
                'ReplayGain toggle and gapless defaults — slice 2 wires these up.',
          ),
        ],
      ),
    );
  }
}
