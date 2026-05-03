import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../shell/settings_sections.dart';
import 'palette_providers.dart';

/// Settings → "Theme" section. One row per [PresetAccent], rendered as
/// a tinted swatch + radio dot. Tapping a swatch persists the choice
/// to SharedPreferences (`theme.defaultPreset`) and updates
/// [themePresetProvider]; the next route push picks up the new neutral
/// palette automatically.
///
/// The default-default is `blue` (slice 7 §2 / §8 step 8). The five
/// values are locked: 6BA8FF / FFA0C8 / A0E8C4 / FFC878 / C0A0FF.
class SettingsThemeSection extends ConsumerWidget {
  const SettingsThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final scale = Theme.of(context).extension<TypographyScale>()!;
    final selected = ref.watch(themePresetProvider);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Theme'),
        Padding(
          padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s2, tokens.s4, tokens.s2),
          child: Text(
            'Default accent — used on every screen except album '
            'detail and now playing, where the album art drives the '
            'tint.',
            style: scale.caption13.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.s4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final preset in PresetAccent.values)
                _Swatch(
                  preset: preset,
                  selected: preset == selected,
                  onTap: () =>
                      ref.read(themePresetProvider.notifier).setPreset(preset),
                ),
            ],
          ),
        ),
        SizedBox(height: tokens.s4),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final PresetAccent preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = kPresetAccents[preset]!;
    final scale = Theme.of(context).extension<TypographyScale>()!;
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(tokens.s2),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.s1,
          vertical: tokens.s2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 48 px circular swatch — matches `s12` in SpaceTokens.
            Container(
              width: tokens.s12,
              height: tokens.s12,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 3,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: selected
                  ? const Center(
                      child: Icon(
                        Icons.check,
                        color: Colors.white,
                        size: 22,
                      ),
                    )
                  : null,
            ),
            SizedBox(height: tokens.s1),
            Text(_label(preset), style: scale.caption13),
          ],
        ),
      ),
    );
  }

  static String _label(PresetAccent preset) {
    switch (preset) {
      case PresetAccent.blue:
        return 'Blue';
      case PresetAccent.pink:
        return 'Pink';
      case PresetAccent.mint:
        return 'Mint';
      case PresetAccent.amber:
        return 'Amber';
      case PresetAccent.lilac:
        return 'Lilac';
    }
  }
}
