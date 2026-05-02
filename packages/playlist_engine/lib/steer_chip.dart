import 'package:meta/meta.dart';

/// Locked vocabulary of 10 steer chips per slice 5 §2. Adding,
/// renaming, or reordering this enum is a breaking change for the UI
/// (chip-set hash keying) and the repo-side test fixtures — keep it
/// in lockstep with the spec.
enum SteerChip {
  // Mood
  happier,
  sadder,
  calmer,
  moreIntense,
  // Tempo
  slower,
  faster,
  // Era
  newer,
  older,
  // Texture
  moreLikeThisArtist,
  differentArtists,
}

/// Per-chip state — TTL counted in remaining ticks. A chip starts at
/// 10, decays by 1 each pick, and clamps at 0 (`isActive` becomes
/// false). Reselecting a chip resets it to 10 (handled at the
/// session/UI layer; see [RadioSession.withChipToggled]).
@immutable
class ChipState {
  /// 0..10. 0 means the chip has decayed and contributes nothing.
  final int ticksRemaining;
  const ChipState(this.ticksRemaining)
      : assert(
          ticksRemaining >= 0 && ticksRemaining <= 10,
          'ticksRemaining must be in [0,10]',
        );

  /// Linear decay: at ticks=10 weight=1.0, at ticks=0 weight=0.0.
  /// Multiplicative kernel application uses `state.weight` to fade
  /// the kernel's effect from full to none.
  double get weight => ticksRemaining / 10.0;

  /// Decrement one tick, clamped at 0. Pure: returns a new instance.
  ChipState tick() => ChipState((ticksRemaining - 1).clamp(0, 10));

  bool get isActive => ticksRemaining > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChipState && other.ticksRemaining == ticksRemaining);

  @override
  int get hashCode => ticksRemaining.hashCode;

  @override
  String toString() => 'ChipState($ticksRemaining)';
}

/// Map of opposing chips. Used by both:
///
/// 1. The UI — tapping `calmer` clears `moreIntense` automatically.
/// 2. The engine — `RadioEngine.next` asserts no conflicting pair is
///    simultaneously active as defense-in-depth (§10 risk 2).
const Map<SteerChip, SteerChip> kChipConflicts = {
  SteerChip.calmer: SteerChip.moreIntense,
  SteerChip.moreIntense: SteerChip.calmer,
  SteerChip.slower: SteerChip.faster,
  SteerChip.faster: SteerChip.slower,
  SteerChip.newer: SteerChip.older,
  SteerChip.older: SteerChip.newer,
  SteerChip.moreLikeThisArtist: SteerChip.differentArtists,
  SteerChip.differentArtists: SteerChip.moreLikeThisArtist,
};
