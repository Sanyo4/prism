import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/ui.dart';

import '../providers/radio_providers.dart';
import '../shell/app_shell.dart';

/// "Radio · seeded from '<title>'" pill that sits above the Upcoming
/// list in the Queue screen.
///
/// Renders [SizedBox.shrink] when no radio session is running. Tap
/// navigates to Home so the user can see the `RadioHomeCard` (which
/// is where they pick a different seed).
///
/// The label string is the only piece of UI copy we lock to the spec
/// verbatim (slice 5 §1 "Queue reads `Radio · seeded from '<title>'`")
/// — keep the middle dot (· U+00B7) and the apostrophes around the
/// label.
class RadioSeedHeader extends ConsumerWidget {
  const RadioSeedHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(radioSessionProvider);
    if (session == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    return InkWell(
      // Tap → Home (Tracks tab is the route Home / Library lives behind
      // in the slice 5 wiring; the RadioHomeCard is rendered there).
      onTap: () =>
          Navigator.of(context).pushReplacementNamed(AppShell.tracksRoute),
      child: Padding(
        padding: EdgeInsets.fromLTRB(tokens.s4, tokens.s3, tokens.s4, tokens.s1),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: tokens.s3, vertical: tokens.s1 + 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.radio_outlined,
                size: 16,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              SizedBox(width: tokens.s1 + 2),
              Flexible(
                child: Text(
                  "Radio · seeded from '${session.seed.label}'",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: scale.caption13.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
