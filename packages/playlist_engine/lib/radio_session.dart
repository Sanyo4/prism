import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'steer_chip.dart';

/// Sealed family identifying the seed of a radio session. Carries
/// just enough to render UI labels — no embedding here; that's on
/// [RadioSession.seedEmbedding] which is computed once at session
/// boot via `RadioEngine.from*` and never re-fetched.
sealed class SeedRef {
  const SeedRef();

  /// Human-friendly label for badges + queue header
  /// (`Radio · seeded from '<label>'`).
  String get label;
}

/// Seed = a single track. `trackId` is the sidecar-derived row id;
/// `title` is the display label.
final class TrackSeed extends SeedRef {
  final int trackId;
  final String title;
  const TrackSeed({required this.trackId, required this.title});

  @override
  String get label => title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackSeed &&
          other.trackId == trackId &&
          other.title == title);

  @override
  int get hashCode => Object.hash(trackId, title);
}

/// Seed = an album mean embedding. `albumKey` is the canonical key
/// (typically `'<album_artist>::<album>'`); `title` is the display
/// label.
final class AlbumSeed extends SeedRef {
  final String albumKey;
  final String title;
  const AlbumSeed({required this.albumKey, required this.title});

  @override
  String get label => title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlbumSeed &&
          other.albumKey == albumKey &&
          other.title == title);

  @override
  int get hashCode => Object.hash(albumKey, title);
}

/// Seed = an artist's mean embedding.
final class ArtistSeed extends SeedRef {
  final String artist;
  @override
  final String label;
  const ArtistSeed({required this.artist, required this.label});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ArtistSeed && other.artist == artist && other.label == label);

  @override
  int get hashCode => Object.hash(artist, label);
}

/// Snapshot of a running radio session. Immutable: every state
/// transition (`tick`, `withChipToggled`, `copyAfterPick`) returns a
/// new instance so providers can drive `==`-based rebuilds without
/// reaching into mutable fields.
@immutable
class RadioSession {
  /// What the user seeded from. Surfaced verbatim by the UI.
  final SeedRef seed;

  /// 1280-dim L2-normalized seed embedding. For track seeds this is
  /// the embedding of [TrackSeed.trackId]; for album/artist seeds
  /// this is the L2-normalized mean of contributing embeddings.
  final Float32List seedEmbedding;

  /// Active steer chips with their TTL. Inactive chips can be either
  /// absent or `ChipState(0)` — both behave the same in scoring; the
  /// UI uses absence.
  final Map<SteerChip, ChipState> chips;

  /// Picks made this session, oldest first. Engine's hard-reject
  /// rule rejects any candidate id present in the last
  /// [FlowScorer.historyWindow] entries, plus session-scoped skip-
  /// spam weighting up to 80 picks (§10 risk 5).
  final List<int> history;

  /// Per-track skip count this session — used by the flow scorer to
  /// extend history-window rejection on rapidly-skipped tracks
  /// (§10 risk 5). Map is sparse.
  final Map<int, int> skipWeights;

  /// Number of tracks the lookahead manager pre-picks. Locked at 5
  /// per §2; exposed here so tests can run with a deeper ring.
  final int lookahead;

  /// Artist key of the last pick — short-circuit for the same-artist
  /// window check when no previous candidate has been resolved yet.
  final String? lastPickArtistKey;

  const RadioSession({
    required this.seed,
    required this.seedEmbedding,
    this.chips = const {},
    this.history = const [],
    this.skipWeights = const {},
    this.lookahead = 5,
    this.lastPickArtistKey,
  });

  /// Returns a new session with [trackId] appended to history,
  /// [artistKey] memoized, every active chip ticked one step, and
  /// the skip-weight map preserved.
  RadioSession copyAfterPick(int trackId, String artistKey) {
    final newHistory = List<int>.unmodifiable([...history, trackId]);
    final newChips = <SteerChip, ChipState>{};
    chips.forEach((c, s) {
      final next = s.tick();
      if (next.isActive) newChips[c] = next;
    });
    return RadioSession(
      seed: seed,
      seedEmbedding: seedEmbedding,
      chips: Map<SteerChip, ChipState>.unmodifiable(newChips),
      history: newHistory,
      skipWeights: skipWeights,
      lookahead: lookahead,
      lastPickArtistKey: artistKey,
    );
  }

  /// Toggles [chip] on at full strength (10 ticks). Clears the
  /// opposing chip in [kChipConflicts] if active. UI calls this on
  /// chip taps; engine asserts the conflict invariant on entry to
  /// `next` as defense-in-depth.
  RadioSession withChipToggled(SteerChip chip) {
    final newChips = Map<SteerChip, ChipState>.from(chips);
    final opposite = kChipConflicts[chip];
    if (opposite != null) {
      newChips.remove(opposite);
    }
    newChips[chip] = const ChipState(10);
    return RadioSession(
      seed: seed,
      seedEmbedding: seedEmbedding,
      chips: Map<SteerChip, ChipState>.unmodifiable(newChips),
      history: history,
      skipWeights: skipWeights,
      lookahead: lookahead,
      lastPickArtistKey: lastPickArtistKey,
    );
  }

  /// Removes [chip] regardless of its current state. Used by the
  /// conflict-resolution path and by UI "clear all chips".
  RadioSession withChipCleared(SteerChip chip) {
    if (!chips.containsKey(chip)) return this;
    final newChips = Map<SteerChip, ChipState>.from(chips)..remove(chip);
    return RadioSession(
      seed: seed,
      seedEmbedding: seedEmbedding,
      chips: Map<SteerChip, ChipState>.unmodifiable(newChips),
      history: history,
      skipWeights: skipWeights,
      lookahead: lookahead,
      lastPickArtistKey: lastPickArtistKey,
    );
  }

  /// Increments the skip count for [trackId] (§10 risk 5).
  /// `RadioEngine` doesn't call this — the lookahead manager is
  /// responsible for detecting skip events and folding them in
  /// before requesting the next pick.
  RadioSession withSkipped(int trackId) {
    final updated = Map<int, int>.from(skipWeights);
    updated[trackId] = (updated[trackId] ?? 0) + 1;
    return RadioSession(
      seed: seed,
      seedEmbedding: seedEmbedding,
      chips: chips,
      history: history,
      skipWeights: Map<int, int>.unmodifiable(updated),
      lookahead: lookahead,
      lastPickArtistKey: lastPickArtistKey,
    );
  }
}
