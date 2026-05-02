import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import '../widgets/home_random_row.dart';

/// Home screen — slice 2 surface is just the "Can't decide?" row
/// underneath a 44 px placeholder for the slice-4 mood chips.
///
/// Slice 4 fills the placeholder; slice 7 polishes the typography and
/// adds the adaptive palette. We keep the placeholder visible (not
/// `Visibility(false)`) so the spacing matches what slice 4 will
/// inherit.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Home',
      currentTab: AppTab.tracks,
      child: ListView(
        children: const [
          // Mood chips placeholder — slice 4 fills.
          SizedBox(height: 44),
          HomeRandomRow(),
        ],
      ),
    );
  }
}
