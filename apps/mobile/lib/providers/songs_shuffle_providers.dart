import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Aggregate state for the Songs-tab shuffle UI. Held in a Notifier so
/// chip + tempo toggles publish a single new value to the deck query.
class SongsShuffleState {
  /// Currently-selected mood chips (multi-select). Empty by default.
  final Set<MoodChip> chips;

  /// Tempo band (or null = "Any tempo").
  final TempoBand? band;

  /// True-Shuffle override. When true, the deck ignores chip selections
  /// and returns a uniformly-random ready set; the chips render dimmed
  /// per spec §2.2.
  final bool trueShuffle;

  /// Infinite radio toggle. Wired to the lookahead trigger in Task 12.
  /// State stored here so the toggle's UI position survives chip changes.
  final bool infinite;

  const SongsShuffleState({
    this.chips = const <MoodChip>{},
    this.band,
    this.trueShuffle = false,
    this.infinite = false,
  });

  SongsShuffleState copyWith({
    Set<MoodChip>? chips,
    Object? band = _sentinel,
    bool? trueShuffle,
    bool? infinite,
  }) {
    return SongsShuffleState(
      chips: chips ?? this.chips,
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

  void setChips(Set<MoodChip> chips) {
    state = state.copyWith(chips: chips);
  }

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
/// Debounced 250 ms (slice 10 §7 risk 3) so rapid chip toggles don't
/// thrash the SQL.
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
    chips: state.chips,
    band: state.band,
    trueShuffle: state.trueShuffle,
  );
});
