import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import '../widgets/home_random_row.dart';
import '../widgets/mood_chip_row.dart';

/// Home screen.
///
/// Layout (top → bottom):
/// - 44 px Mood chip row (slice 4): Happy / Sad / Chill / Energetic /
///   Focus, locked order.
/// - "Can't decide?" album row (slice 2's `HomeRandomRow`).
/// - Slice 7 will add adaptive palette + hero polish.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Home',
      currentTab: AppTab.tracks,
      child: ListView(
        children: const [
          SizedBox(height: 8),
          MoodChipRow(),
          SizedBox(height: 8),
          HomeRandomRow(),
        ],
      ),
    );
  }
}
