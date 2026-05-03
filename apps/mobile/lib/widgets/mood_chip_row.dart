import 'package:flutter/material.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../screens/mood_results_screen.dart';

/// Selection model for [MoodChipRow]. Two factories:
///
/// - [MoodChipController.single] — slice-4 behaviour: a tap navigates
///   to `MoodResultsScreen` for that chip and the row never holds a
///   selection. Home consumes this.
/// - [MoodChipController.multi] — slice-10 behaviour: tap toggles the
///   chip in/out of [selected]; [onChanged] fires with the resulting
///   set. SongsShuffleTab consumes this.
///
/// Defense against the slice-1..4 widget tests: existing
/// `mood_chip_row_test.dart` only asserts the locked visual order and
/// the FilterChip count, both of which the refactor preserves.
class MoodChipController {
  /// Internal mode flag — `false` for slice-4 single push, `true` for
  /// slice-10 multi-select.
  final bool isMulti;

  /// Currently-selected chips (multi mode only). Always empty in single
  /// mode — single-mode taps don't accumulate state.
  final Set<MoodChip> selected;

  /// Multi-mode change callback. `null` in single mode.
  final ValueChanged<Set<MoodChip>>? onChanged;

  const MoodChipController._({
    required this.isMulti,
    required this.selected,
    required this.onChanged,
  });

  /// Slice-4 single-select: tap pushes [MoodResultsScreen]. The
  /// controller carries no selection state.
  const MoodChipController.single()
      : this._(isMulti: false, selected: const <MoodChip>{}, onChanged: null);

  /// Slice-10 multi-select: tap toggles into [initial]. [onChanged]
  /// fires with the resulting set so the parent can refresh its query.
  /// Note: [selected] is a mutable copy of [initial], so taps can
  /// directly mutate it (and subsequent taps see the updated state).
  MoodChipController.multi({
    required Set<MoodChip> initial,
    required ValueChanged<Set<MoodChip>> onChanged,
  }) : this._(isMulti: true, selected: Set.from(initial), onChanged: onChanged);
}

/// Five Material 3 FilterChips in **locked order**: Happy / Sad / Chill
/// / Energetic / Focus. Slice-10 lift adds the multi-select mode via
/// [controller]; default is the slice-4 single-select push.
///
/// Heights are 44 px (slice 1's placeholder reserved exactly that)
/// so dropping the row in place doesn't push the rest of Home down.
class MoodChipRow extends StatelessWidget {
  const MoodChipRow({
    super.key,
    this.controller = const MoodChipController.single(),
    this.dim = false,
  });

  /// Selection / dispatch model. Defaults to single-select for the
  /// pre-existing Home consumer.
  final MoodChipController controller;

  /// When `true`, all chips render at 50% opacity (Songs-tab
  /// True-Shuffle ON state per spec §2.2). The chips remain tappable —
  /// dimming is purely visual.
  final bool dim;

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
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: tokens.s4),
        itemCount: visualOrder.length,
        separatorBuilder: (_, _) => SizedBox(width: tokens.s2),
        itemBuilder: (context, i) {
          final chip = visualOrder[i];
          final isSelected =
              controller.isMulti && controller.selected.contains(chip);
          final body = FilterChip(
            selected: isSelected,
            label: Text(_label(chip)),
            avatar: Icon(_iconFor(chip), size: 18),
            onSelected: (_) => _onTap(context, chip),
          );
          return Opacity(opacity: dim ? 0.5 : 1.0, child: body);
        },
      ),
    );
  }

  void _onTap(BuildContext context, MoodChip chip) {
    if (!controller.isMulti) {
      Navigator.of(context).push(MoodResultsScreen.route(chip));
      return;
    }
    if (controller.selected.contains(chip)) {
      controller.selected.remove(chip);
    } else {
      controller.selected.add(chip);
    }
    controller.onChanged?.call(controller.selected);
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
