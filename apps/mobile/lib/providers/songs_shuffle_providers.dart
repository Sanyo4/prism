import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Aggregate state for the Songs-tab shuffle UI. Held in a Notifier so
/// tempo + True-Shuffle / Infinite toggles publish a single new value
/// to the deck query.
///
/// Slice 10 originally held a multi-select `chips` set here, but with
/// True-Shuffle ON the deck query bypassed the set entirely (chips
/// rendered dimmed but had no effect). The vibe-steer flow has since
/// been consolidated to the Home/Search single-select-pushes-to-results
/// pattern: tap a mood chip in this tab → push `MoodResultsScreen` for
/// that one chip. Multi-select state is no longer kept here.
class SongsShuffleState {
  /// Tempo band (or null = "Any tempo").
  final TempoBand? band;

  /// True-Shuffle override. When true, the deck returns a uniformly-
  /// random ready set; the chip row remains a single-select push to
  /// MoodResultsScreen, so the toggle is no longer a chip-aware mode.
  final bool trueShuffle;

  /// Infinite radio toggle. Wired to the lookahead trigger in Task 12.
  /// State stored here so the toggle's UI position survives chip
  /// changes elsewhere.
  final bool infinite;

  const SongsShuffleState({
    this.band,
    this.trueShuffle = false,
    this.infinite = false,
  });

  SongsShuffleState copyWith({
    Object? band = _sentinel,
    bool? trueShuffle,
    bool? infinite,
  }) {
    return SongsShuffleState(
      band: band == _sentinel ? this.band : band as TempoBand?,
      trueShuffle: trueShuffle ?? this.trueShuffle,
      infinite: infinite ?? this.infinite,
    );
  }
}

const _sentinel = Object();

class SongsShuffleStateNotifier extends Notifier<SongsShuffleState> {
  @override
  SongsShuffleState build() => const SongsShuffleState();

  void setBand(TempoBand? band) {
    state = state.copyWith(band: band);
  }

  void setTrueShuffle(bool value) {
    state = state.copyWith(trueShuffle: value);
  }

  void setInfinite(bool value) {
    state = state.copyWith(infinite: value);
  }
}

final songsShuffleStateProvider =
    NotifierProvider<SongsShuffleStateNotifier, SongsShuffleState>(
  SongsShuffleStateNotifier.new,
);

/// The visible deck. Re-runs `VibeShuffleQuery` on every state change.
/// Debounced 250 ms (slice 10 §7 risk 3) so rapid toggles don't thrash
/// the SQL.
final shuffleDeckProvider =
    FutureProvider.autoDispose<List<ShuffleTrack>>((ref) async {
  final state = ref.watch(songsShuffleStateProvider);
  // Debounce: wait 250 ms; if the state changes during the wait the
  // FutureProvider re-runs and the in-flight call is auto-disposed.
  final completer = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 250), completer.complete);
  ref.onDispose(timer.cancel);
  await completer.future;
  final db = await ref.watch(cacheDbProvider.future);
  return db.vibeShuffle.run(
    chips: const <MoodChip>{},
    band: state.band,
    trueShuffle: state.trueShuffle,
  );
});
