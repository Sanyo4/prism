/// Prism playback — `just_audio` + `audio_service` wrapper and queue.
///
/// Slice 1 surface: [QueueService] + [QueueSnapshot] + [QueueZone] +
/// [PlaybackService] (+ [AudioPlayerPort] for testability). The
/// `AudioHandler` bridge (step 8) lives in `apps/mobile`, not this
/// package.
///
/// Slice 9 surface: [LocalPlayerHandle] adapter that lets `prism_cast`'s
/// duck-typed `LocalAudioHandle` wrap the slice-1 [AudioPlayerPort]
/// without the dependency cycle (`prism_cast` would otherwise need
/// to import `prism_playback`).
library;

export 'src/audio_player_port.dart';
export 'src/cast/local_player_handle.dart';
export 'src/playback_service.dart';
export 'src/queue_service.dart';
export 'src/queue_zone.dart';
export 'src/radio_mode.dart';
