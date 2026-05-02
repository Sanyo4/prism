import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';
import 'library_providers.dart';

/// Snapshot of the latest ingest run for the Settings screen + the
/// Re-scan button. `null` when no run has happened yet this session.
class IngestUiState {
  final bool running;
  final IngestSummary? lastSummary;
  final int processed;
  final Object? error;

  const IngestUiState({
    required this.running,
    required this.lastSummary,
    required this.processed,
    this.error,
  });

  static const idle = IngestUiState(
    running: false,
    lastSummary: null,
    processed: 0,
    error: null,
  );

  IngestUiState copyWith({
    bool? running,
    IngestSummary? lastSummary,
    int? processed,
    Object? error,
  }) =>
      IngestUiState(
        running: running ?? this.running,
        lastSummary: lastSummary ?? this.lastSummary,
        processed: processed ?? this.processed,
        error: error,
      );
}

/// Owns the manual Re-scan workflow. The notifier composes the slice-1
/// scanner with slice-4's [IngestCoordinator]; when [rescan] is called
/// it walks the configured library root, feeds the resulting
/// `Stream<ScanEvent>` to the coordinator, and surfaces progress.
class IngestController extends Notifier<IngestUiState> {
  @override
  IngestUiState build() => IngestUiState.idle;

  /// Triggers one ingest pass. Idempotent — concurrent calls coalesce
  /// into the existing run.
  Future<void> rescan() async {
    if (state.running) return;
    state = state.copyWith(running: true, error: null, processed: 0);
    try {
      final root = await ref.read(libraryRootProvider.future);
      final db = await ref.read(cacheDbProvider.future);
      final scanner = LibraryScanner();
      final token = CancellationToken();
      final coordinator = IngestCoordinator(cache: db);
      final scanEvents = scanner.scan(root, token: token);
      final ingestStream = coordinator.run(scanEvents);
      IngestSummary? finalSummary;
      await for (final e in ingestStream) {
        switch (e) {
          case IngestProgress(:final processed):
            state = state.copyWith(processed: processed);
          case IngestComplete(:final summary):
            finalSummary = summary;
        }
      }
      state = state.copyWith(
        running: false,
        lastSummary: finalSummary,
      );
      // Trigger downstream re-reads (mood / vibe / measured RG / cache
      // stats) so the UI picks up the new state.
      ref.invalidate(measuredReplayGainProvider);
      ref.invalidate(cacheStatsProvider);
      ref.invalidate(moodResultsProvider);
      ref.invalidate(vibeResultsProvider);
    } on FileSystemException catch (e) {
      state = state.copyWith(running: false, error: e);
    } catch (e) {
      state = state.copyWith(running: false, error: e);
    }
  }
}

final ingestControllerProvider =
    NotifierProvider<IngestController, IngestUiState>(
  IngestController.new,
);

/// Mood-row results, parameterised by chip. The provider re-reads on
/// every cache invalidation (Re-scan completes, etc.).
final moodResultsProvider =
    FutureProvider.family<List<RankedTrack>, MoodChip>((ref, chip) async {
  final db = await ref.watch(cacheDbProvider.future);
  return db.moods.run(chip);
});

/// Vibe results, parameterised by `(mood, band)` pair. Same
/// invalidation contract as [moodResultsProvider].
final vibeResultsProvider = FutureProvider.family<List<VibeTrack>,
    ({VibeMoodChip mood, TempoBand? band})>((ref, params) async {
  final db = await ref.watch(cacheDbProvider.future);
  return db.vibes.run(mood: params.mood, band: params.band);
});
