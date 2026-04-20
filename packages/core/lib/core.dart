/// Prism core — pure Dart primitives consumed by `packages/playback` and
/// `apps/mobile`. Zero Flutter imports; must be usable by `dart test`
/// without the Flutter SDK.
///
/// Slice 1 surface: [Track] data model, audio-path helpers, the
/// cancelable [LibraryScanner] that yields [ScanEvent]s, and the pure
/// ReplayGain dB↔linear math. `packages/playback` consumes
/// [dbToLinear] to attenuate `just_audio`'s volume.
library;

export 'src/models/track.dart';
export 'src/paths/audio_paths.dart';
export 'src/replay_gain.dart';
export 'src/scanner/cancellation_token.dart';
export 'src/scanner/library_scanner.dart';
export 'src/scanner/scan_event.dart';
