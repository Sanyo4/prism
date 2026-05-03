import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_playlist_engine/playlist_engine.dart';
import 'package:prism_ui/ui.dart';

import '../providers/radio_providers.dart';

/// Locked-vocabulary steer chip bar (10 chips, slice 5 §2). Visible
/// only when a radio session is running; otherwise [SizedBox.shrink].
///
/// Visual order is locked too — Mood (4) → Tempo (2) → Era (2) →
/// Texture (2) — surfaced via [SteerChipBar.visualOrder] so the widget
/// test can assert it without reaching into private state. Same locked-
/// order discipline as `MoodChipRow` from slice 4.
///
/// Mutual exclusion (`kChipConflicts`) is enforced two ways:
///   1. **Engine** — `RadioSession.withChipToggled` clears the
///      opposite chip; `RadioEngine.next` asserts the invariant as
///      defense-in-depth.
///   2. **UI** — tap dispatches `radioSessionProvider.notifier
///      .toggleChip`, which calls into the engine; the resulting
///      session has `chips[opposite]` removed and the next
///      [AnimatedSwitcher] frame renders the conflict cleared.
///
/// The whole row is wrapped in a 250 ms [AnimatedSwitcher] keyed on a
/// hash of the active-chip set so chip-state transitions slide in
/// rather than pop. Slice 7 polish may swap this for the "AeroSlider"
/// transition; the API stays the same.
class SteerChipBar extends ConsumerWidget {
  const SteerChipBar({super.key});

  /// Locked rendering order. Asserted in `steer_chip_bar_test.dart` —
  /// drift here means the spec needs updating, not the test.
  static const List<SteerChip> visualOrder = <SteerChip>[
    // Mood (4)
    SteerChip.happier,
    SteerChip.sadder,
    SteerChip.calmer,
    SteerChip.moreIntense,
    // Tempo (2)
    SteerChip.slower,
    SteerChip.faster,
    // Era (2)
    SteerChip.newer,
    SteerChip.older,
    // Texture (2)
    SteerChip.moreLikeThisArtist,
    SteerChip.differentArtists,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(radioSessionProvider);
    if (session == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    final activeChips = session.chips;
    final activeKey = _activeChipsKey(activeChips);

    return SizedBox(
      height: 48,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        // Slide + fade default — matches slice 5 §4 "ships the default
        // 250 ms fade+slide; slice 7 polishes."
        child: ListView.separated(
          key: ValueKey<int>(activeKey),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: tokens.s4, vertical: tokens.s1 + 2),
          itemCount: visualOrder.length,
          separatorBuilder: (_, _) => SizedBox(width: tokens.s2),
          itemBuilder: (context, i) {
            final chip = visualOrder[i];
            final state = activeChips[chip];
            final isActive = state?.isActive ?? false;
            // Linear weight fade — at fresh-toggle (10 ticks) the chip
            // renders fully opaque; as ticks decay the chip's avatar
            // glyph fades but the pill remains tappable.
            final weight = state?.weight ?? 0.0;
            return FilterChip(
              selected: isActive,
              label: Text(_label(chip)),
              avatar: Opacity(
                opacity: 0.4 + 0.6 * weight,
                child: Icon(_iconFor(chip), size: 18),
              ),
              onSelected: (_) =>
                  // ignore: discarded_futures
                  ref.read(radioSessionProvider.notifier).toggleChip(chip),
            );
          },
        ),
      ),
    );
  }

  /// Builds a deterministic int key from the active-chip map so
  /// [AnimatedSwitcher] swaps cleanly on every state transition. We
  /// fold both the chip enum index and its tick count so toggling a
  /// chip *and* tick decay both flip the key.
  static int _activeChipsKey(Map<SteerChip, ChipState> chips) {
    var key = 0;
    for (final chip in visualOrder) {
      final state = chips[chip];
      key = (key * 31 + (state?.ticksRemaining ?? 0)) & 0x7fffffff;
    }
    return key;
  }

  static String _label(SteerChip chip) {
    switch (chip) {
      case SteerChip.happier:
        return 'Happier';
      case SteerChip.sadder:
        return 'Sadder';
      case SteerChip.calmer:
        return 'Calmer';
      case SteerChip.moreIntense:
        return 'More intense';
      case SteerChip.slower:
        return 'Slower';
      case SteerChip.faster:
        return 'Faster';
      case SteerChip.newer:
        return 'Newer';
      case SteerChip.older:
        return 'Older';
      case SteerChip.moreLikeThisArtist:
        return 'More like this artist';
      case SteerChip.differentArtists:
        return 'Different artists';
    }
  }

  static IconData _iconFor(SteerChip chip) {
    switch (chip) {
      case SteerChip.happier:
        return Icons.sentiment_very_satisfied_outlined;
      case SteerChip.sadder:
        return Icons.sentiment_dissatisfied_outlined;
      case SteerChip.calmer:
        return Icons.spa_outlined;
      case SteerChip.moreIntense:
        return Icons.flash_on_outlined;
      case SteerChip.slower:
        return Icons.slow_motion_video_outlined;
      case SteerChip.faster:
        return Icons.fast_forward_outlined;
      case SteerChip.newer:
        return Icons.update_outlined;
      case SteerChip.older:
        return Icons.history_outlined;
      case SteerChip.moreLikeThisArtist:
        return Icons.person_pin_outlined;
      case SteerChip.differentArtists:
        return Icons.shuffle_outlined;
    }
  }
}
