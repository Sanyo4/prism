import 'package:flutter/material.dart';

/// Slim icon button used as the trailing affordance on Home's
/// "Can't decide?" row and the two RandomTab section headers. Wraps
/// [IconButton] only because we want a one-line callsite that
/// mirrors a Material 3 affordance — the actual semantics are no
/// different from a stock IconButton.
class RefreshIconButton extends StatelessWidget {
  const RefreshIconButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Refresh',
  });

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: const Icon(Icons.refresh),
    );
  }
}
