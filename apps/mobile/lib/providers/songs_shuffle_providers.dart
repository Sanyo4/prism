import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

import 'cache_db_providers.dart';

/// Aggregate state for the Songs-tab shuffle UI. Held in a Notifier so
/// chips + tempo + True-Shuffle / Infinite toggles publish a single new
/// value to the deck query.
///
/// Slice-11 §B2 reinstates the multi-select chip set after the
/// slice-10d single-select-push consolidation was retired. The deck
/// query (`shuffleDeckProvider`) now passes `chips` through under both
/// True-Shuffle and Tempo modes — True-Shuffle randomises *order*, but
/// the chip filter still constrains *which* tracks are eligible.
class SongsShuffleState {
  /// Currently-selected mood chips. Empty = no chip filter.
  final Set<MoodChip> chips;

  /// Tempo band (or null = "Any tempo").
  final TempoBand? band;

  /// True-Shuffle override. When true, the deck order is uniformly
  /// random; chips (if any) still filter the eligible set.
  final bool trueShuffle;

  /// Infinite radio toggle. Wired to the lookahead trigger in Task 12.
  /// State stored here so the toggle's UI position survives chip
  /// changes elsewhere.
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
    state = state.copyWith(chips: Set<MoodChip>.unmodifiable(chips));
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
/// Debounced 250 ms (slice 10 §7 risk 3) so rapid toggles don't thrash
/// the SQL.
///
/// Slice-11 §B2: passes `state.chips` through unconditionally — the
/// query branches internally on whether `trueShuffle` is set, but in
/// both branches non-empty chips constrain the eligible set. The
/// previous slice-10b D bug had True-Shuffle drop the chip filter
/// entirely; that path is now closed.
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
