import 'package:emajtee/features/player/controllers/lecture_playback_controller.dart';
import 'package:emajtee/features/player/widgets/unified_scrub_bar.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Video player widget for the stitched lecture player.
///
/// Renders the active [VideoPlayerController] from [controller] with a custom
/// play/pause overlay and a [UnifiedScrubBar] that spans the entire lecture
/// duration.
class LectureVideoPlayer extends StatefulWidget {
  const LectureVideoPlayer({
    required this.controller,
    required this.isFullScreen,
    required this.onToggleFullScreen,
    required this.onSeek,
    super.key,
  });

  final LecturePlaybackController controller;
  final bool isFullScreen;
  final VoidCallback onToggleFullScreen;
  final ValueChanged<double> onSeek;

  @override
  State<LectureVideoPlayer> createState() => _LectureVideoPlayerState();
}

class _LectureVideoPlayerState extends State<LectureVideoPlayer> {
  bool _controlsVisible = true;
  bool _scrubbing = false;

  void _toggleControls() => setState(() => _controlsVisible = !_controlsVisible);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: widget.controller.snapshot,
      builder: (context, snap, _) {
        final vpc = widget.controller.activeController;

        // Error state.
        if (snap.error != null) {
          return AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snap.error!,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        // Loading state.
        if (vpc == null || !vpc.value.isInitialized) {
          return const AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator(color: Colors.white)),
            ),
          );
        }

        final aspectRatio =
            vpc.value.aspectRatio > 0 ? vpc.value.aspectRatio : 16 / 9;

        // Rebuild VideoPlayer with a key that changes on segment swap so
        // Flutter creates a fresh widget for the new VideoPlayerController.
        final videoWidget = VideoPlayer(
          key: ValueKey(snap.activeVideoIndex),
          vpc,
        );

        final player = AspectRatio(
          aspectRatio: aspectRatio,
          child: GestureDetector(
            onTap: _toggleControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FittedBox(
                  child: SizedBox(
                    width: vpc.value.size.width,
                    height: vpc.value.size.height,
                    child: videoWidget,
                  ),
                ),
                if (_controlsVisible) _OverlayControls(
                  isPlaying: snap.isPlaying,
                  onPlayPause: snap.isPlaying
                      ? widget.controller.pause
                      : widget.controller.play,
                  isFullScreen: widget.isFullScreen,
                  onToggleFullScreen: widget.onToggleFullScreen,
                ),
              ],
            ),
          ),
        );

        return ColoredBox(
          color: Colors.black,
          // In fullscreen the parent Expanded gives us bounded height, so we
          // must use mainAxisSize.max to fill it and let Expanded(video) share
          // the space with the scrub bar.  In non-fullscreen, min is correct
          // so the column wraps the AspectRatio player tightly.
          child: Column(
            mainAxisSize: widget.isFullScreen
                ? MainAxisSize.max
                : MainAxisSize.min,
            children: [
              if (widget.isFullScreen)
                Expanded(child: Center(child: player))
              else
                player,
              _buildScrubBar(snap),
            ],
          ),
        );
      },
    );
  }

  Widget _buildScrubBar(PlaybackSnapshot snap) {
    // Collect segment start times for dividers, skipping the first (always 0).
    final boundaries = widget.controller.schedule
        .map((e) => e.globalStartTime)
        .where((t) => t > 0)
        .toList();

    return ColoredBox(
      color: Colors.black,
      child: Padding(
        // Left padding must exceed _kBackGestureWidth (20 px) so no drag on
        // the track can start inside the iOS swipe-back zone. With the 7 px
        // thumb radius, a 24 px start inset puts the leftmost touchable point
        // at x = 31 px — safely outside the 20 px back-gesture overlay.
        padding: const EdgeInsetsDirectional.only(
          start: 24,
          end: 12,
          top: 2,
          bottom: 2,
        ),
        child: UnifiedScrubBar(
          position: _scrubbing
              ? snap.globalPosition
              : snap.globalPosition,
          duration: snap.totalDuration,
          segmentBoundaries: boundaries,
          onSeekStart: () => setState(() => _scrubbing = true),
          onSeekEnd: () => setState(() => _scrubbing = false),
          onSeek: widget.onSeek,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _OverlayControls extends StatelessWidget {
  const _OverlayControls({
    required this.isPlaying,
    required this.onPlayPause,
    required this.isFullScreen,
    required this.onToggleFullScreen,
  });

  final bool isPlaying;
  final VoidCallback onPlayPause;
  final bool isFullScreen;
  final VoidCallback onToggleFullScreen;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Semi-transparent centre play/pause button.
        Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            child: IconButton(
              iconSize: 40,
              padding: const EdgeInsets.all(12),
              icon: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: onPlayPause,
            ),
          ),
        ),
        // Fullscreen toggle in the top-right corner.
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Colors.black.withValues(alpha: 0.35),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: isFullScreen ? 'Exit fullscreen' : 'Enter fullscreen',
              iconSize: 22,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: Icon(
                isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                color: Colors.white,
              ),
              onPressed: onToggleFullScreen,
            ),
          ),
        ),
      ],
    );
  }
}
