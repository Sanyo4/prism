/// Computes a responsive column count for grid layouts based on the
/// available width and a target tile width. Always clamps to
/// `[min, max]` so the grid never collapses to one column or sprawls
/// indefinitely.
///
/// Usage:
/// ```dart
/// LayoutBuilder(
///   builder: (context, constraints) {
///     final cols = columnsForWidth(
///       constraints.maxWidth,
///       targetTileWidth: 180,
///       min: 2,
///       max: 6,
///     );
///     return GridView.builder(
///       gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
///         crossAxisCount: cols,
///         ...,
///       ),
///       ...
///     );
///   },
/// )
/// ```
int columnsForWidth(
  double maxWidth, {
  required int targetTileWidth,
  required int min,
  required int max,
}) {
  if (targetTileWidth <= 0 || maxWidth <= 0) return min;
  final raw = (maxWidth / targetTileWidth).toInt();
  if (raw < min) return min;
  if (raw > max) return max;
  return raw;
}
