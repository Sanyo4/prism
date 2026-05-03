/// Slice 8 widget test for [ModelDownloadCard]. Asserts that the
/// card renders the expected text + control affordances for each
/// `DownloadPhase`. Uses `ProviderScope.overrides` to feed canned
/// `DownloadProgress` values; the underlying `ModelDownloader`
/// instance is replaced with a no-op fake so button taps don't
/// trigger real network I/O.
///
/// **Why this test lives in `apps/mobile`** rather than
/// `packages/llm_mobile`: the card is the UI layer and consumes the
/// Riverpod providers in `providers/llm_providers_mobile.dart`.
/// Track A's tests cover the downloader's behaviour; Track B covers
/// the rendered states.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/llm_providers_mobile.dart';
import 'package:mobile/theme/prism_theme.dart';
import 'package:mobile/widgets/model_download_card.dart';
import 'package:prism_llm_mobile/llm_mobile.dart';

void main() {
  group('ModelDownloadCard', () {
    testWidgets('connecting phase shows spinner + label', (tester) async {
      await _pumpCard(
        tester,
        progress: const DownloadProgress(
          phase: DownloadPhase.connecting,
          receivedBytes: 0,
          totalBytes: 1006051493,
        ),
      );

      expect(find.text('On-device LLM'), findsOneWidget);
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('downloading phase shows progress + Pause + Cancel',
        (tester) async {
      await _pumpCard(
        tester,
        progress: const DownloadProgress(
          phase: DownloadPhase.downloading,
          receivedBytes: 503025747,
          totalBytes: 1006051493,
          bytesPerSecond: 5 * 1024 * 1024.0, // 5 MB/s
          eta: Duration(seconds: 100),
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.textContaining('5.0 MB/s'), findsOneWidget);
    });

    testWidgets('paused phase shows Resume + Cancel', (tester) async {
      await _pumpCard(
        tester,
        progress: const DownloadProgress(
          phase: DownloadPhase.paused,
          receivedBytes: 250000000,
          totalBytes: 1006051493,
        ),
      );

      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('verifying phase shows Verifying… label',
        (tester) async {
      await _pumpCard(
        tester,
        progress: const DownloadProgress(
          phase: DownloadPhase.verifying,
          receivedBytes: 1006051493,
          totalBytes: 1006051493,
        ),
      );

      expect(find.text('Verifying…'), findsOneWidget);
      // No buttons during verification.
      expect(find.text('Pause'), findsNothing);
      expect(find.text('Resume'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('failed phase shows error banner + Retry', (tester) async {
      await _pumpCard(
        tester,
        progress: const DownloadProgress(
          phase: DownloadPhase.failed,
          receivedBytes: 0,
          totalBytes: 1006051493,
          errorMessage: 'Checksum mismatch. Tap to retry.',
        ),
      );

      expect(find.text('Checksum mismatch. Tap to retry.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('empty pin shows the pin-missing card', (tester) async {
      // Override the spec with one that has an empty SHA256 — the
      // card refuses to render its normal body and shows the
      // "pin missing" state per slice 8 §10 risk 8.
      final emptySpec = CactusModelSpec(
        weightsUrl: Uri.parse('https://example.invalid/weights.zip'),
        revision: 'fake',
        fileName: 'fake.zip',
        sizeBytes: 1,
        sha256Hex: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cactusModelSpecProvider.overrideWithValue(emptySpec),
            modelDownloaderProvider.overrideWithValue(_FakeDownloader()),
            modelDownloadStateProvider.overrideWith(
              (ref) => const Stream<DownloadProgress>.empty(),
            ),
            connectivityProvider.overrideWith(
              (ref) => Stream<ConnectivityResult>.value(
                ConnectivityResult.wifi,
              ),
            ),
          ],
          child: MaterialApp(
            theme: PrismTheme.light(),
            home: const Scaffold(
              body: SingleChildScrollView(child: ModelDownloadCard()),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('On-device LLM — pin missing'), findsOneWidget);
      expect(
        find.textContaining('Download blocked'),
        findsOneWidget,
      );
    });
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required DownloadProgress progress,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        modelDownloaderProvider.overrideWithValue(_FakeDownloader()),
        modelDownloadStateProvider.overrideWith(
          (ref) => Stream<DownloadProgress>.value(progress),
        ),
        connectivityProvider.overrideWith(
          (ref) => Stream<ConnectivityResult>.value(
            ConnectivityResult.wifi,
          ),
        ),
      ],
      child: MaterialApp(
        theme: PrismTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: ModelDownloadCard()),
        ),
      ),
    ),
  );
  // pumpAndSettle is unsafe here — the card's `ref.listen` for
  // connectivity changes runs once on the first frame; subsequent
  // pumps would chase the stream's broadcast forever. A single pump
  // resolves the initial stream value into the AsyncData state.
  await tester.pump();
}

/// No-op `ModelDownloader` for the test seam. The real class has a
/// private `_dio` field in its positional constructor signature, so
/// we can't subclass cleanly across packages — `implements` plus
/// `noSuchMethod` is the supported pattern. The card never calls
/// into anything we haven't stubbed (button taps are not exercised
/// because the canned `DownloadProgress` drives every state we want
/// to assert).
class _FakeDownloader implements ModelDownloader {
  @override
  Stream<DownloadProgress> get progress =>
      const Stream<DownloadProgress>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<bool> isComplete() async => false;

  // `noSuchMethod` absorbs the private fields (`_dio`, `_cancel`,
  // `_progress`, `_verifiedComplete`) and the public fields (`spec`,
  // `paths`, `diskHeadroomBytes`) that the card never reads. Dart's
  // analyzer is happy with this when we pass `Invocation` through.
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
