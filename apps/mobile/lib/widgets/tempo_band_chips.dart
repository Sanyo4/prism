import 'package:flutter/material.dart';
import 'package:prism_core/core.dart';

/// Segmented control for the Vibe browse tempo band: `calm | mid | hot
/// | off`. The "off" segment maps to `null` — anything passes the
/// tempo gate.
class TempoBandChips extends StatelessWidget {
  const TempoBandChips({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  /// Currently-selected band. `null` means "off / any tempo".
  final TempoBand? selected;
  final ValueChanged<TempoBand?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<TempoBand?>(
      segments: const [
        ButtonSegment(
          value: null,
          label: Text('Off'),
          icon: Icon(Icons.all_inclusive_outlined),
        ),
        ButtonSegment(
          value: TempoBand.calm,
          label: Text('Calm'),
          icon: Icon(Icons.spa_outlined),
        ),
        ButtonSegment(
          value: TempoBand.mid,
          label: Text('Mid'),
          icon: Icon(Icons.music_note_outlined),
        ),
        ButtonSegment(
          value: TempoBand.hot,
          label: Text('Hot'),
          icon: Icon(Icons.local_fire_department_outlined),
        ),
      ],
      selected: <TempoBand?>{selected},
      onSelectionChanged: (set) => onChanged(set.first),
      multiSelectionEnabled: false,
      emptySelectionAllowed: false,
    );
  }
}
