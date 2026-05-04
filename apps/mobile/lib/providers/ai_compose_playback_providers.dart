import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_core/core.dart';

/// Captures the most-recently-launched AI Compose playlist so the
/// end-of-queue observer can decide whether the drain event should
/// trigger the "Keep playing?" sheet.
class AiComposePlayback {
  /// Resolved tracks (mapped to live `Track` rows via slice-5's
  /// `trackByIdLookupProvider`). Used as the cluster seed when the
  /// user accepts the sheet.
  final List<Track> tracks;

  /// Original LLM prompt — surfaced to the user verbatim and used as
  /// the steering hint passed into `startFromCluster`.
  final String prompt;

  /// Display label (typically the playlist's blurb).
  final String label;

  const AiComposePlayback({
    required this.tracks,
    required this.prompt,
    required this.label,
  });
}

class AiComposePlaybackNotifier extends Notifier<AiComposePlayback?> {
  @override
  AiComposePlayback? build() => null;

  void set(AiComposePlayback playback) {
    state = playback;
  }

  void clear() {
    state = null;
  }
}

final aiComposePlaybackProvider =
    NotifierProvider<AiComposePlaybackNotifier, AiComposePlayback?>(
  AiComposePlaybackNotifier.new,
);
