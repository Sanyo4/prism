import 'package:flutter/material.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

/// Selection model for [MoodChipRow]. Two factories:
///
/// - [MoodChipController.single] — taps fire [onTap] but the row holds
///   no selection state (visual no-op chip). Slice-11 §C1 retired the
///   old `MoodResultsScreen` push, so single-mode is now an inert
///   surface left behind for any future read-only consumer; without
///   an [onTap] handler the chip taps no-op. The Home consumer of
///   single-mode was retired in §C2.
/// - [MoodChipController.multi] — slice-10 behaviour: tap toggles the
///   chip in/out of [selected]; [onChanged] fires with the resulting
///   set. SongsShuffleTab consumes this.
///
/// Defense against the slice-1..4 widget tests: existing
/// `mood_chip_row_test.dart` only asserts the locked visual order and
/// the FilterChip count, both of which the refactor preserves.
class MoodChipController {
  /// Internal mode flag — `false` for slice-4 single tap, `true` for
  /// slice-10 multi-select.
  final bool isMulti;

  /// Currently-selected chips (multi mode only). Always empty in single
  /// mode — single-mode taps don't accumulate state.
  final Set<MoodChip> selected;

  /// Multi-mode change callback. `null` in single mode.
  final ValueChanged<Set<MoodChip>>? onChanged;

  /// Single-mode tap callback. `null` in multi mode (taps go through
  /// [onChanged] there).
  final void Function(MoodChip chip)? onTap;

  const MoodChipController._({
    required this.isMulti,
    required this.selected,
    required this.onChanged,
    required this.onTap,
  });

  /// Single-select: tap fires [onTap] (when set). The controller
  /// carries no selection state. With no [onTap] the chip is inert —
  /// useful for read-only renders.
  const MoodChipController.single({void Function(MoodChip chip)? onTap})
      : this._(
          isMulti: false,
          selected: const <MoodChip>{},
          onChanged: null,
          onTap: onTap,
        );

  /// Slice-10 multi-select: tap toggles into [initial]. [onChanged]
  /// fires with the resulting set so the parent can refresh its query.
  const MoodChipController.multi({
    required Set<MoodChip> initial,
    required ValueChanged<Set<MoodChip>> onChanged,
  }) : this._(
          isMulti: true,
          selected: initial,
          onChanged: onChanged,
          onTap: null,
        );
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
            onSelected: (_) => _onTap(chip),
          );
          return Opacity(opacity: dim ? 0.5 : 1.0, child: body);
        },
      ),
    );
  }

  void _onTap(MoodChip chip) {
    if (!controller.isMulti) {
      controller.onTap?.call(chip);
      return;
    }
    final next = Set<MoodChip>.from(controller.selected);
    if (next.contains(chip)) {
      next.remove(chip);
    } else {
      next.add(chip);
    }
    controller.onChanged?.call(next);
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
