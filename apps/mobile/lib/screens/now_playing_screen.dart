import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prism_core/core.dart';

import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../widgets/radio_badge.dart';
import '../widgets/steer_chip_bar.dart';

/// Full-screen "what's playing right now" surface — title / artist /
/// album, a scrubber, and prev / play-pause / next transport controls.
///
/// Wiring:
/// - [nowPlayingProvider] → metadata strip at the top.
/// - [positionProvider] / [durationProvider] → scrubber value + max.
/// - [playerStateProvider] → play/pause icon + disabled state during
///   buffering.
///
/// Scrub handling uses local state (`_scrubValue`) to pause the flow
/// of [positionProvider] updates into the slider while the user is
/// dragging — otherwise every 60 Hz tick would yank the thumb back to
/// the real playhead mid-drag.
///
/// Visuals are plain Material 3 — slice 7 replaces the whole screen
/// with hero art, adaptive palette, and custom typography.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  /// Non-null while the user is actively dragging the scrubber.
  /// Value is in seconds (the Slider's min/max are also seconds so
  /// we don't have to multiply Durations on every tick).
  double? _scrubSeconds;

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(nowPlayingProvider).value;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? track?.duration;
    final playerState = ref.watch(playerStateProvider).value;

    return AppShell(
      title: 'Now Playing',
      currentTab: AppTab.nowPlaying,
      child: track == null
          ? const _IdleView()
          : _PlayerView(
              track: track,
              position: position,
              duration: duration,
              playerState: playerState,
              scrubSeconds: _scrubSeconds,
              onScrubChange: (v) => setState(() => _scrubSeconds = v),
              onScrubEnd: (v) {
                // ignore: discarded_futures
                ref
                    .read(playbackServiceProvider)
                    .seek(Duration(milliseconds: (v * 1000).round()));
                setState(() => _scrubSeconds = null);
              },
              onPlayPause: () {
                final service = ref.read(playbackServiceProvider);
                // ignore: discarded_futures
                if (service.playing) {
                  service.pause();
                } else {
                  service.play();
                }
              },
              onPrevious: () {
                // ignore: discarded_futures
                ref.read(playbackServiceProvider).skipToPrevious();
              },
              onNext: () {
                // ignore: discarded_futures
                ref.read(playbackServiceProvider).skipToNext();
              },
            ),
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Nothing is playing.\n\nTap a track on the Tracks tab to start.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _PlayerView extends StatelessWidget {
  const _PlayerView({
    required this.track,
    required this.position,
    required this.duration,
    required this.playerState,
    required this.scrubSeconds,
    required this.onScrubChange,
    required this.onScrubEnd,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
  });

  final Track track;
  final Duration position;
  final Duration? duration;
  final PlayerState? playerState;
  final double? scrubSeconds;
  final ValueChanged<double> onScrubChange;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationSeconds =
        duration == null ? 0.0 : duration!.inMilliseconds / 1000.0;
    final positionSeconds =
        scrubSeconds ?? (position.inMilliseconds / 1000.0);
    final canScrub = durationSeconds > 0;
    final isPlaying = playerState?.playing ?? false;
    final isBuffering = playerState?.processingState ==
            ProcessingState.loading ||
        playerState?.processingState == ProcessingState.buffering;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slice 5: RADIO badge above title; SizedBox.shrink when no
          // radio session is running.
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: RadioBadge(),
          ),
          // Metadata strip — single column so it wraps cleanly on the
          // Pixel 9 Pro Fold's outer screen without a specialised layout.
          Text(
            _displayTitle(track),
            style: theme.textTheme.headlineSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            track.artist ?? track.albumArtist ?? 'Unknown artist',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (track.album != null) ...[
            const SizedBox(height: 2),
            Text(
              track.album!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const Spacer(),
          // Slice 5: SteerChipBar above the AeroSlider (slice-1's
          // Slider stand-in). SizedBox.shrink when no radio session.
          const SteerChipBar(),
          // Scrubber: min=0, max=duration seconds. When duration is
          // unknown we render a disabled track at its natural zero so
          // the layout doesn't jump when the backend probes it.
          Slider(
            min: 0,
            max: canScrub ? durationSeconds : 1.0,
            value: canScrub
                ? positionSeconds.clamp(0.0, durationSeconds).toDouble()
                : 0.0,
            onChanged: canScrub ? onScrubChange : null,
            onChangeEnd: canScrub ? onScrubEnd : null,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(Duration(
                  milliseconds: (positionSeconds * 1000).round()))),
              Text(duration == null ? '—:—' : _formatDuration(duration!)),
            ],
          ),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.skip_previous),
                onPressed: onPrevious,
              ),
              IconButton(
                iconSize: 64,
                icon: isBuffering
                    ? const SizedBox(
                        width: 40,
                        height: 40,
                        child:
                            CircularProgressIndicator(strokeWidth: 3),
                      )
                    : Icon(isPlaying
                        ? Icons.pause_circle
                        : Icons.play_circle),
                onPressed: isBuffering ? null : onPlayPause,
              ),
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.skip_next),
                onPressed: onNext,
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Same fallback as TracksScreen — untagged files display their
/// filename minus extension. Kept local to the screen for now; if a
/// third consumer appears, promote to a `prism_core` getter.
String _displayTitle(Track t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final path = t.path;
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}

String _formatDuration(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:$ss';
  }
  return '$m:$ss';
}
