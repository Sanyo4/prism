import 'package:flutter/material.dart';

/// Dense, primary-tinted label that groups related preference rows.
/// Sits on the scaffold background (not an elevated container) so the
/// scroll of sections reads like one long sheet of preferences
/// rather than a stack of cards.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Muted subtitle row paired with [SettingsSectionHeader] to signal
/// "this section is a stub; the real rows arrive in slice N". The
/// pairing is deliberate: an empty section is invisible and looks
/// like a bug, while a labelled placeholder makes the deferred scope
/// legible at a glance.
class SettingsSectionPlaceholder extends StatelessWidget {
  const SettingsSectionPlaceholder({super.key, required this.subtitle});
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(
        subtitle,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
