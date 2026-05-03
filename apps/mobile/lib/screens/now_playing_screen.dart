import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/cast_providers.dart';
import '../providers/playback_providers.dart';
import '../shell/app_shell.dart';
import '../theme/palette_providers.dart';
import '../widgets/cast_sheet.dart';
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
/// Slice 7 §8 step 10 — wraps the whole subtree in `Theme(data:
/// ..copyWith)` so [AlbumPalette] flows through to the scrub-bar fill,
/// the play-button gradient, and the `Glass` tint behind the metadata
/// strip. Aurora variant is `player`; the accent override pipes the
/// resolved dominant into the primary blob.
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

    final palette = _resolvePalette(track);
    final theme = Theme.of(context);
    final activeTransport = ref.watch(transportProvider);
    final isRemote = activeTransport.id != 'local';

    return Theme(
      data: theme.copyWith(
        // Slice 7 §8 step 10: now-playing forces the AuroraVariant
        // to `player` so the primary blob honors the override.
        extensions: _withPalette(
          theme,
          palette.copyWith(variant: AuroraVariant.player),
        ),
      ),
      child: AppShell(
        title: 'Now Playing',
        currentTab: AppTab.nowPlaying,
        useAurora: AuroraVariant.player,
        auroraAccentOverride:
            palette.isNeutral ? null : palette.dominant,
        // Slice 9 — cast icon. `Icons.cast_connected` when a remote
        // transport (DLNA / Chromecast) is active; `Icons.cast`
        // otherwise. Tap always opens the sheet.
        actions: <Widget>[
          IconButton(
            tooltip: 'Cast',
            icon: Icon(isRemote ? Icons.cast_connected : Icons.cast),
            onPressed: () => CastSheet.show(context),
          ),
        ],
        child: track == null
            ? const _IdleView()
            : _PlayerView(
                track: track,
                position: position,
                duration: duration,
                playerState: playerState,
                palette: palette,
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
      ),
    );
  }

  /// Mirrors [AlbumDetailScreen]'s palette resolver, keyed by the
  /// track's album-derived key. Until art metadata is wired into the
  /// playback queue we have no `coverUrl` per track — falls through to
  /// neutral and the screen renders against the default preset
  /// (slice 7 §10 risk 9).
  AlbumPalette _resolvePalette(Track? track) {
    if (track == null) return const AlbumPalette.neutral();
    // The mobile app currently surfaces album art via the
    // [albumsProvider] aggregation. NowPlayingScreen does not have
    // direct access to that art URL on the Track row; until slice 8
    // pipes art into PlaybackService we rely on the neutral palette
    // here. Hook left open via [paletteForProvider] for the upgrade.
    final repoAsync = ref.watch(paletteRepositoryProvider);
    if (!repoAsync.hasValue) return const AlbumPalette.neutral();
    return const AlbumPalette.neutral();
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<SpaceTokens>()!;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.s6),
        child: const Text(
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
    required this.palette,
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
  final AlbumPalette palette;
  final double? scrubSeconds;
  final ValueChanged<double> onScrubChange;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onPlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<SpaceTokens>()!;
    final scale = theme.extension<TypographyScale>()!;
    final durationSeconds =
        duration == null ? 0.0 : duration!.inMilliseconds / 1000.0;
    final positionSeconds =
        scrubSeconds ?? (position.inMilliseconds / 1000.0);
    final canScrub = durationSeconds > 0;
    final isPlaying = playerState?.playing ?? false;
    final isBuffering = playerState?.processingState ==
            ProcessingState.loading ||
        playerState?.processingState == ProcessingState.buffering;

    final scrubColor =
        palette.isNeutral ? theme.colorScheme.primary : palette.dominant;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.s6,
        vertical: tokens.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Slice 5: RADIO badge above title; SizedBox.shrink when no
          // radio session is running.
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: RadioBadge(),
          ),
          // Slice 7 — wrap the metadata strip in Glass(medium) so the
          // album-tinted blob underneath stays legible behind the type.
          Glass(
            intensity: GlassIntensity.medium,
            radius: tokens.s4,
            tint: palette.isNeutral ? null : palette.dominant,
            padding: EdgeInsets.all(tokens.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _displayTitle(track),
                  style: scale.display28,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: tokens.s1),
                Text(
                  track.artist ?? track.albumArtist ?? 'Unknown artist',
                  style: scale.body16.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (track.album != null) ...[
                  SizedBox(height: tokens.s1),
                  Text(
                    track.album!,
                    style: scale.caption13.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const Spacer(),
          // Slice 5: SteerChipBar above the scrubber. SizedBox.shrink
          // when no radio session.
          const SteerChipBar(),
          // Scrubber: min=0, max=duration seconds. Slice 7 — tints the
          // active track segment and thumb with the album dominant.
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: scrubColor,
              thumbColor: scrubColor,
              overlayColor: scrubColor.withValues(alpha: 0.16),
            ),
            child: Slider(
              min: 0,
              max: canScrub ? durationSeconds : 1.0,
              value: canScrub
                  ? positionSeconds.clamp(0.0, durationSeconds).toDouble()
                  : 0.0,
              onChanged: canScrub ? onScrubChange : null,
              onChangeEnd: canScrub ? onScrubEnd : null,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(Duration(
                    milliseconds: (positionSeconds * 1000).round())),
                style: scale.caption13,
              ),
              Text(
                duration == null ? '—:—' : _formatDuration(duration!),
                style: scale.caption13,
              ),
            ],
          ),
          SizedBox(height: tokens.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.skip_previous),
                onPressed: onPrevious,
              ),
              _PlayPauseButton(
                palette: palette,
                isBuffering: isBuffering,
                isPlaying: isPlaying,
                onPressed: onPlayPause,
              ),
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.skip_next),
                onPressed: onNext,
              ),
            ],
          ),
          SizedBox(height: tokens.s4),
        ],
      ),
    );
  }
}

/// Slice 7 — circular play/pause button with a palette-driven gradient.
/// Falls back to a flat primary fill when the palette is neutral so a
/// non-hero surface (slice-7 spec stays neutral on MiniPlayer / queue)
/// never renders a gradient.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.palette,
    required this.isBuffering,
    required this.isPlaying,
    required this.onPressed,
  });

  final AlbumPalette palette;
  final bool isBuffering;
  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = palette.isNeutral
        ? null
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[palette.dominant, palette.secondary],
          );
    return Material(
      color: palette.isNeutral
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      shape: const CircleBorder(),
      child: Ink(
        decoration: BoxDecoration(
          gradient: fill,
          shape: BoxShape.circle,
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: isBuffering ? null : onPressed,
          child: SizedBox(
            width: 72,
            height: 72,
            child: isBuffering
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  )
                : Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 40,
                    color: palette.isNeutral
                        ? theme.colorScheme.primary
                        : palette.textOnDominant,
                  ),
          ),
        ),
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

/// Replaces the [AlbumPalette] entry in [theme.extensions] with
/// [palette] and returns the resulting iterable. `theme.extensions`
/// is `Map<Object, ThemeExtension<dynamic>>`; we strip the existing
/// `AlbumPalette` (the neutral seed) and append the per-album one.
Iterable<ThemeExtension<dynamic>> _withPalette(
  ThemeData theme,
  AlbumPalette palette,
) sync* {
  for (final ext in theme.extensions.values) {
    if (ext is AlbumPalette) continue;
    yield ext;
  }
  yield palette;
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
