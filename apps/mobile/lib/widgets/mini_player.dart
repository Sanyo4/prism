import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:prism_core/core.dart';
import 'package:prism_ui/ui.dart';

import '../providers/playback_providers.dart';
import '../screens/now_playing_screen.dart';
import 'embedded_art.dart';

/// Floating glass pill that surfaces the current track above the
/// bottom nav. Matches `wireframe/music/screens/mobile-shell.jsx`'s
/// `MiniPlayer` — a 44 px square art chip, two-line title/artist
/// strip, play/pause button, next button, and a thin progress hairline
/// across the bottom. Tapping anywhere except the buttons opens the
/// full-screen [NowPlayingScreen] overlay.
///
/// Renders [SizedBox.shrink] when nothing is loaded into the queue
/// — there's no point in showing a glass strip with no track to
/// describe. The bottom nav still lays out correctly because the
/// pill collapses to zero height + zero margin.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(nowPlayingProvider).value;
    if (track == null) return const SizedBox.shrink();

    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? track.duration;
    final state = ref.watch(playerStateProvider).value;
    final isPlaying = state?.playing ?? false;
    final isBuffering = state?.processingState == ProcessingState.loading ||
        state?.processingState == ProcessingState.buffering;

    final theme = Theme.of(context);
    final palette = theme.extension<AlbumPalette>();
    final accent = palette?.isNeutral == false
        ? palette!.dominant
        : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openNowPlaying(context),
        child: Glass(
          intensity: GlassIntensity.heavy,
          radius: 22,
          padding: const EdgeInsets.fromLTRB(8, 8, 10, 12),
          child: Stack(
            children: [
              Row(
                children: [
                  // 44 px album art chip with embedded-FLAC fallback.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: _MiniArt(trackPath: track.path, accent: accent),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Title / artist column.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _displayTitle(track),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          track.artist ??
                              track.albumArtist ??
                              'Unknown artist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Play / pause button — chrome-y gradient pill.
                  _PillButton(
                    accent: accent,
                    icon: isPlaying ? Icons.pause : Icons.play_arrow,
                    isBuffering: isBuffering,
                    onTap: () {
                      final svc = ref.read(playbackServiceProvider);
                      // ignore: discarded_futures
                      if (svc.playing) {
                        svc.pause();
                      } else {
                        svc.play();
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  // Next button — flat icon, transparent background.
                  IconButton(
                    iconSize: 22,
                    splashRadius: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: Icon(
                      Icons.skip_next,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.7),
                    ),
                    onPressed: () {
                      // ignore: discarded_futures
                      ref.read(playbackServiceProvider).skipToNext();
                    },
                  ),
                ],
              ),
              // Thin progress hairline along the bottom edge.
              Positioned(
                left: 4,
                right: 4,
                bottom: 0,
                child: _ProgressHairline(
                  position: position,
                  duration: duration,
                  accent: accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openNowPlaying(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.0),
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, _, _) => const NowPlayingScreen(),
        transitionsBuilder: (_, animation, _, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            )),
            child: child,
          );
        },
      ),
    );
  }
}

class _MiniArt extends StatelessWidget {
  const _MiniArt({required this.trackPath, required this.accent});
  final String trackPath;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: EmbeddedArtImage(trackPath),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, _) {
        if (frame == null) return _placeholder();
        return child;
      },
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }

  Widget _placeholder() {
    return ColoredBox(
      color: accent.withValues(alpha: 0.6),
      child: const Center(
        child: Icon(Icons.album_outlined, size: 24, color: Colors.white70),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.accent,
    required this.icon,
    required this.isBuffering,
    required this.onTap,
  });

  final Color accent;
  final IconData icon;
  final bool isBuffering;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: Ink(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[accent, accent.withValues(alpha: 0.85)],
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: accent.withValues(alpha: 0.40),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: isBuffering ? null : onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: isBuffering
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _ProgressHairline extends StatelessWidget {
  const _ProgressHairline({
    required this.position,
    required this.duration,
    required this.accent,
  });

  final Duration position;
  final Duration? duration;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final ms = duration?.inMilliseconds ?? 0;
    final pct = ms == 0 ? 0.0 : (position.inMilliseconds / ms).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 2,
        child: Stack(
          children: [
            Container(
              color: Colors.black.withValues(alpha: 0.08),
            ),
            FractionallySizedBox(
              widthFactor: pct.toDouble(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      accent,
                      accent.withValues(alpha: 0.7),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _displayTitle(Track t) {
  final title = t.title;
  if (title != null && title.isNotEmpty) return title;
  final path = t.path;
  final slash = path.lastIndexOf('/');
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? base : base.substring(0, dot);
}
