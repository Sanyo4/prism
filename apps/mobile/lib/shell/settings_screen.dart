import 'dart:io';

import 'package:flutter/material.dart';

import '../settings/cast_section.dart';
import '../theme/settings_theme_section.dart';
import 'settings_library.dart';
import 'settings_llm_section.dart';
import 'settings_llm_section_mobile.dart';
import 'settings_online_metadata.dart';
import 'settings_sections.dart';

/// Settings surface. Slice-1 placeholders → slice-2 metadata section →
/// slice-4 library re-scan + cache stats. Slice 6 added the Ollama LLM
/// row; slice 7 added the Theme preset picker; slice 8 swaps the Ollama
/// LLM section for the Cactus-backed [SettingsLlmSectionMobile] on
/// Android. Playback section remains placeholder until a later slice
/// surfaces the RG toggle.
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
        children: [
          const SettingsOnlineMetadataSection(),
          const SettingsLibrarySection(),
          // Slice 6 / Slice 8 — LLM section appended below the
          // slice-4 Library row. Section order stays stable so the
          // slice-1 widget test (which scrolls until "Playback" is
          // visible) still resolves past this section. Slice 8 swaps
          // the Ollama-backed `SettingsLlmSection` for the Cactus-
          // backed `SettingsLlmSectionMobile` on Android only;
          // Linux desktop keeps the Ollama section so slice 6's
          // verification still passes.
          if (Platform.isAndroid)
            const SettingsLlmSectionMobile()
          else
            const SettingsLlmSection(),
          // Slice 7 — Theme preset picker. Sits above Playback so the
          // existing widget test (which scrolls "Playback" into view)
          // still resolves; we deliberately don't reorder slice 1's
          // anchor section.
          const SettingsThemeSection(),
          // Slice 9 — Cast & DLNA. Sits between Theme and Playback so
          // the slice-1 widget-test scroll-until-"Playback" still
          // resolves (the section adds rows above, not below, the
          // anchor).
          const CastSection(),
          const SettingsSectionHeader(title: 'Playback'),
          const SettingsSectionPlaceholder(
            subtitle:
                'ReplayGain toggle and gapless defaults — wired in a later slice.',
          ),
        ],
      ),
    );
  }
}
