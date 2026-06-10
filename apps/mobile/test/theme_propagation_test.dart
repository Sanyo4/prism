import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app.dart';
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/llm_providers.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';

void main() {
  // Slice-10b §A3: app is locked to light theme via themeMode:
  // ThemeMode.light. Settings + Mood Results no longer pick up the
  // platform's dark setting.
  testWidgets('PrismApp stays in light theme even with dark platformBrightness',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(() => tester.platformDispatcher.clearAllTestValues());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.down,
              detail: 'overridden in widget test',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
        ],
        child: const PrismApp(),
      ),
    );
    await tester.pump();

    // Find any MaterialApp descendant and verify its resolved theme is light.
    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.light);
    expect(materialApp.theme?.brightness, Brightness.light);

    // The active build context's resolved Theme should also be Brightness.light.
    final BuildContext context = tester.element(find.byType(MaterialApp));
    expect(Theme.of(context).brightness, Brightness.light);
  });
}
