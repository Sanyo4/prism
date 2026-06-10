/// Logical bucket an entry in [QueueSnapshot] belongs to at a given
/// moment. Zones are a UI-facing grouping; the underlying audio player
/// sees only the flat projection ([QueueSnapshot.flat]).
///
/// Zone ownership is a function of **position**, not identity — moving
/// a PlayNext row into Upcoming via `QueueService.move` transfers
/// ownership to Upcoming, by design. That's what users expect from a
/// "drag this into the queue" interaction.
enum QueueZone {
  /// Already-played tracks. Read-only in slice 1's `QueueScreen`.
  history,

  /// The one track the player is currently emitting audio from. Never
  /// empty while a track is active; becomes `null` when the queue
  /// drains and there is nothing left to play.
  current,

  /// FIFO "play these next" overlay. `QueueService.playNext(t)` inserts
  /// at the head; `advance()` promotes the head to [current] before
  /// touching [upcoming]. Cleared in one shot by `clearPlayNext()`.
  playNext,

  /// Contextual tail — what tapping a track from `TracksScreen` loaded.
  /// Promotes to [current] via `advance()` only when [playNext] is empty.
  upcoming,
}
