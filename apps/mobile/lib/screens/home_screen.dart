import 'package:flutter/material.dart';
import 'package:prism_ui/ui.dart';

import '../shell/app_shell.dart';
import '../widgets/home_random_row.dart';
import '../widgets/mood_chip_row.dart';
import '../widgets/radio_home_card.dart';

/// Home screen.
///
/// Layout (top → bottom):
/// - 44 px Mood chip row (slice 4): Happy / Sad / Chill / Energetic /
///   Focus, locked order.
/// - **Slice 5: `RadioHomeCard` — up to three recent radio seeds (LRU)**.
/// - "Can't decide?" album row (slice 2's `HomeRandomRow`).
/// - Slice 7 wraps the body in `AuroraBackground(home)` and reads its
///   inter-section gaps off the [SpaceTokens] extension.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return AppShell(
      title: 'Home',
      currentTab: AppTab.tracks,
      useAurora: AuroraVariant.home,
      child: ListView(
        children: [
          SizedBox(height: tokens.s2),
          const MoodChipRow(),
          SizedBox(height: tokens.s2),
          const RadioHomeCard(),
          SizedBox(height: tokens.s2),
          const HomeRandomRow(),
        ],
      ),
    );
  }
}
