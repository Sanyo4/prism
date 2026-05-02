import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show PlayerState;
import 'package:prism_core/core.dart';
import 'package:prism_playback/playback.dart';

import 'cache_db_providers.dart';

/// Re-export the queue surface from `prism_playback` so every screen
/// can `import '../providers/playback_providers.dart'` once and reach
/// `queueProvider` + its types without a second import. The queue
/// itself still *lives* in `prism_playback` — this is sugar, not a
/// second definition.
export 'package:prism_playback/playback.dart'
    show PlaybackService, QueueService, QueueSnapshot, QueueZone, queueProvider;

/// Eager, container-scoped [PlaybackService].
///
/// Two wiring details matter:
///
/// 1. `onAdvance` / `onRetreat` drive the queue, not the player. Both
///    [QueueService.advance] and [QueueService.retreat] update the
///    snapshot, which then flows back via [ref.listen] below and makes
///    the player seek. Keeping the queue as the single source of truth
///    prevents the queue and the player from drifting out of sync.
/// 2. `fireImmediately: true` means the listener fires with the empty
///    snapshot at wire-up. That forces a first [PlaybackService.syncSnapshot]
///    call and exercises the "drained queue → pause" branch — no
///    special-case at app boot.
final playbackServiceProvider = Provider<PlaybackService>((ref) {
  final service = PlaybackService(
    onAdvance: () => ref.read(queueProvider.notifier).advance(),
    onRetreat: () => ref.read(queueProvider.notifier).retreat(),
    // Slice-4: prefer measured RG (sidecar cache) over tag RG when
    // the row is `status='ready'`. The lookup reads off
    // `measuredReplayGainProvider`'s AsyncValue — null while the cache
    // is still loading, falling cleanly back to tag values until then.
    measuredReplayGainLookup: measuredRgLookupOf(ref),
  );
  ref.listen<QueueSnapshot>(
    queueProvider,
    (prev, next) {
      // Listener signature is synchronous; `syncSnapshot` returns a
      // future we intentionally don't await — the service serialises
      // its own operations so we can't race it from here.
      service.syncSnapshot(next);
    },
    fireImmediately: true,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Stream of the currently-playing [Track] (or `null` when nothing is
/// loaded).
///
/// Derived from [PlaybackService.currentTrackStream] — which already
/// joins the snapshot with the player's `currentIndexStream`. The UI
/// consumes this instead of cross-referencing `queueProvider` and the
/// player's index: there's exactly one source of truth for "what's
/// audibly playing right now".
final nowPlayingProvider = StreamProvider<Track?>((ref) {
  final service = ref.watch(playbackServiceProvider);
  return service.currentTrackStream;
});

/// Live playhead position. Emits at roughly 60 Hz when playing; the
/// UI layer may build on every tick for slice 1 (NowPlayingScreen
/// renders a single scrubber, so the rebuild cost is negligible).
final positionProvider = StreamProvider<Duration>((ref) {
  final service = ref.watch(playbackServiceProvider);
  return service.positionStream;
});

/// Duration of the currently-playing source. `null` while loading or
/// when the backend hasn't probed the stream yet — callers should
/// degrade gracefully (e.g. disable the scrubber) rather than assume
/// a fallback length.
final durationProvider = StreamProvider<Duration?>((ref) {
  final service = ref.watch(playbackServiceProvider);
  return service.durationStream;
});

/// `just_audio`'s [PlayerState] stream, exposed directly so the UI can
/// read both `playing` and `processingState` in one subscription. We
/// accept the leak of a `just_audio` type into the UI because slice 1's
/// NowPlayingScreen needs both dimensions (the play/pause icon and the
/// loading spinner); wrapping them in a bespoke domain type is
/// unjustified ceremony at this size.
final playerStateProvider = StreamProvider<PlayerState>((ref) {
  final service = ref.watch(playbackServiceProvider);
  return service.playerStateStream;
});
