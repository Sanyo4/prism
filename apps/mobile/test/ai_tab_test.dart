import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/cast_providers.dart';
import 'package:mobile/providers/llm_providers.dart';
import 'package:mobile/providers/playlists_provider.dart';
import 'package:mobile/screens/ai_tab.dart';
import 'package:mobile/screens/new_vibe.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/compose_card.dart';
import 'package:prism_cast/cast.dart';
import 'package:prism_core/core.dart';
import 'package:prism_llm_desktop/llm_desktop.dart';

void main() {
  testWidgets('AI tab renders ComposeCard + prompt suggestions',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.up,
              detail: 'overridden',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
          playlistsProvider.overrideWith(
            (ref) async => const <PlaylistRecord>[],
          ),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const AiTabScreen(),
          routes: {
            NewVibeSheet.routeName: (ctx) {
              final args = ModalRoute.of(ctx)?.settings.arguments;
              return NewVibeSheet(
                initialPrompt: args is String ? args : null,
              );
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ComposeCard), findsOneWidget);
    expect(find.text('Try a prompt'), findsOneWidget);
    expect(find.text('Rainy Sunday jazz'), findsOneWidget);
    expect(find.text('Workout pump'), findsOneWidget);
    expect(find.text('Recent generations'), findsNothing,
        reason: 'No recent playlists => section absent');
  });

  testWidgets('AI tab Recent generations renders when playlists exist',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final fixtures = <PlaylistRecord>[
      PlaylistRecord(
        id: 1,
        title: 'Rainy Sunday Jazz',
        blurb: 'A mellow morning',
        prompt: 'rainy sunday jazz',
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 5, 1),
        trackPaths: const ['/a.flac', '/b.flac'],
      ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.up,
              detail: 'overridden',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
          playlistsProvider.overrideWith((ref) async => fixtures),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const AiTabScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recent generations'), findsOneWidget);
    expect(find.text('Rainy Sunday Jazz'), findsOneWidget);
    expect(find.text('2 tracks'), findsOneWidget);
  });

  testWidgets('Tapping a prompt tile pushes NewVibeSheet with initialPrompt',
      (tester) async {
    tester.view.physicalSize = const Size(500, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    String? capturedArgs;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ollamaHealthProvider.overrideWith((ref) async* {
            yield const OllamaHealth(
              status: OllamaHealthStatus.up,
              detail: 'overridden',
            );
          }),
          castDiscoveryProvider.overrideWith(
            (ref) => const Stream<List<DlnaDevice>>.empty(),
          ),
          playlistsProvider.overrideWith(
            (ref) async => const <PlaylistRecord>[],
          ),
        ],
        child: MaterialApp(
          theme: PrismTheme.light(),
          home: const AiTabScreen(),
          onGenerateRoute: (settings) {
            if (settings.name == NewVibeSheet.routeName) {
              capturedArgs = settings.arguments as String?;
              return MaterialPageRoute(
                settings: settings,
                builder: (_) => const Scaffold(
                  body: Text('NewVibe stub'),
                ),
              );
            }
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workout pump'));
    await tester.pumpAndSettle();
    expect(capturedArgs, 'Workout pump');
  });
}
