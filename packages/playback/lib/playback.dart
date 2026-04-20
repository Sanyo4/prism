/// Prism playback — `just_audio` + `audio_service` wrapper and queue.
///
/// Slice 1 surface: [QueueService] + [QueueSnapshot] + [QueueZone] +
/// [PlaybackService] (+ [AudioPlayerPort] for testability). The
/// `AudioHandler` bridge (step 8) lives in `apps/mobile`, not this
/// package.
library;

export 'src/audio_player_port.dart';
export 'src/playback_service.dart';
export 'src/queue_service.dart';
export 'src/queue_zone.dart';
