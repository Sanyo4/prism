import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/responsive_columns.dart';

void main() {
  group('columnsForWidth', () {
    test('phone-width snaps to min', () {
      expect(
        columnsForWidth(360, targetTileWidth: 180, min: 2, max: 6),
        2,
      );
    });

    test('foldable mid-width yields more cols', () {
      expect(
        columnsForWidth(800, targetTileWidth: 180, min: 2, max: 6),
        4,
      );
    });

    test('tablet-width clamps to max', () {
      expect(
        columnsForWidth(2152, targetTileWidth: 180, min: 2, max: 6),
        6,
      );
    });

    test('artist tile target works for 3..8 range', () {
      expect(columnsForWidth(360, targetTileWidth: 110, min: 3, max: 8), 3);
      expect(columnsForWidth(800, targetTileWidth: 110, min: 3, max: 8), 7);
      expect(columnsForWidth(2152, targetTileWidth: 110, min: 3, max: 8), 8);
    });

    test('zero or negative target tile width returns min', () {
      expect(columnsForWidth(800, targetTileWidth: 0, min: 2, max: 6), 2);
    });
  });
}
