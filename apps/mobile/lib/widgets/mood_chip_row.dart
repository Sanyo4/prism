import 'package:flutter/material.dart';
import 'package:prism_core/core.dart';

import '../screens/mood_results_screen.dart';

/// Five Material 3 FilterChips in **locked order**: Happy / Sad / Chill
/// / Energetic / Focus. Order is enforced by the visualOrder list in
/// the body — never reorder these without bumping the slice DoD.
///
/// Heights are 44 px (slice 1's placeholder reserved exactly that)
/// so dropping the row in place doesn't push the rest of Home down.
class MoodChipRow extends StatelessWidget {
  const MoodChipRow({super.key});

  /// Locked rendering order. Visible to widget tests so the order can
  /// be asserted without reaching into private state.
  static const List<MoodChip> visualOrder = <MoodChip>[
    MoodChip.happy,
    MoodChip.sad,
    MoodChip.chill,
    MoodChip.energetic,
    MoodChip.focus,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: visualOrder.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chip = visualOrder[i];
          return FilterChip(
            // FilterChip with selected=false renders as a plain pill —
            // ideal for the home row where "tap to navigate" is the
            // intended action, not "toggle". When the user lands on
            // the results screen the chip becomes selected via the
            // results screen's own chip row (out of scope for slice 4
            // — current tap is push + pop).
            selected: false,
            label: Text(_label(chip)),
            avatar: Icon(_iconFor(chip), size: 18),
            onSelected: (_) {
              Navigator.of(context).push(MoodResultsScreen.route(chip));
            },
          );
        },
      ),
    );
  }

  static String _label(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return 'Happy';
      case MoodChip.sad:
        return 'Sad';
      case MoodChip.chill:
        return 'Chill';
      case MoodChip.energetic:
        return 'Energetic';
      case MoodChip.focus:
        return 'Focus';
    }
  }

  static IconData _iconFor(MoodChip chip) {
    switch (chip) {
      case MoodChip.happy:
        return Icons.sentiment_very_satisfied_outlined;
      case MoodChip.sad:
        return Icons.sentiment_dissatisfied_outlined;
      case MoodChip.chill:
        return Icons.spa_outlined;
      case MoodChip.energetic:
        return Icons.flash_on_outlined;
      case MoodChip.focus:
        return Icons.center_focus_strong_outlined;
    }
  }
}
