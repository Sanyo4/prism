import 'package:flutter/material.dart';

import '../theme/settings_theme_section.dart';
import 'settings_library.dart';
import 'settings_llm_section.dart';
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
          // Slice 6 — LLM section appended below the slice-4 Library
          // row. Order kept stable so the slice-1 widget test (which
          // asserts visible section headers via `scrollUntilVisible`)
          // still resolves "Playback" past this section.
          SettingsLlmSection(),
          // Slice 7 — Theme preset picker. Sits above Playback so the
          // existing widget test (which scrolls "Playback" into view)
          // still resolves; we deliberately don't reorder slice 1's
          // anchor section.
          SettingsThemeSection(),
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
