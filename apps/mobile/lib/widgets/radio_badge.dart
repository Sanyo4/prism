import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/radio_providers.dart';

/// Slice 5 "RADIO" pill that sits above the Now Playing title.
///
/// Renders [SizedBox.shrink] when no radio session is active — never
/// errors, never warnings; the parent layout treats it as
/// zero-height invisible. When active, it's an 11pt uppercase pill
/// using the theme's `primary` palette.
///
/// 11pt was chosen so the pill sits visibly above an `headlineSmall`
/// title without crowding it; tweak in slice 7's polish pass if the
/// adaptive palette work needs a different rhythm.
class RadioBadge extends ConsumerWidget {
  const RadioBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOn = ref.watch(radioModeProvider);
    if (!isOn) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'RADIO',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
