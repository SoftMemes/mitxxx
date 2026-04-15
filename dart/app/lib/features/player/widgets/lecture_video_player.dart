import 'dart:async';

import 'package:emajtee/features/cast/widgets/cast_button.dart';
import 'package:emajtee/features/player/controllers/lecture_playback_controller.dart';
import 'package:emajtee/features/player/widgets/unified_scrub_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

/// Video player widget for the stitched lecture player.
///
/// Renders the active [VideoPlayerController] from [controller] with a custom
/// controls overlay (play/pause, skip ±10s, speed, fullscreen) and a
/// [UnifiedScrubBar] that spans the entire lecture duration.
///
/// In non-fullscreen the scrub bar is laid out below the video and always
/// visible. In fullscreen the scrub bar becomes part of the auto-hiding
/// overlay — tap to reveal, auto-hides after a few seconds.
class LectureVideoPlayer extends ConsumerStatefulWidget {
  const LectureVideoPlayer({
    required this.controller,
    required this.isFullScreen,
    required this.onToggleFullScreen,
    required this.onSeek,
    this.onScrubStart,
    this.onScrubEnd,
    super.key,
  });

  final LecturePlaybackController controller;
  final bool isFullScreen;
  final VoidCallback onToggleFullScreen;
  final ValueChanged<double> onSeek;

  /// Called with the current position when the user starts dragging the scrub bar.
  final ValueChanged<double>? onScrubStart;

  /// Called with the target position when the user releases the scrub bar.
  final ValueChanged<double>? onScrubEnd;

  @override
  ConsumerState<LectureVideoPlayer> createState() =>
      _LectureVideoPlayerState();
}

class _LectureVideoPlayerState extends ConsumerState<LectureVideoPlayer> {
  static const _autoHideDelay = Duration(seconds: 3);
  static const List<double> _speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  bool _controlsVisible = true;
  bool _scrubbing = false;
  double? _pendingSeekTarget;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _restartHideTimer();
  }

  @override
  void didUpdateWidget(covariant LectureVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isFullScreen != widget.isFullScreen) {
      // On entering/leaving fullscreen show controls and restart the timer.
      setState(() => _controlsVisible = true);
      _restartHideTimer();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Restart the auto-hide countdown. Only active in fullscreen; in the
  /// inline view the overlay hides on tap but doesn't auto-hide.
  void _restartHideTimer() {
    _hideTimer?.cancel();
    if (!widget.isFullScreen) return;
    _hideTimer = Timer(_autoHideDelay, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartHideTimer();
  }

  /// Called whenever the user interacts with a control — keeps them on-screen
  /// while they're using them.
  void _nudgeHideTimer() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _onSeek(double secs) {
    setState(() {
      _pendingSeekTarget = secs;
      _scrubbing = true;
    });
    widget.onSeek(secs);
    _nudgeHideTimer();
  }

  void _skipBy(double deltaSeconds, PlaybackSnapshot snap) {
    final target = (snap.globalPosition + deltaSeconds)
        .clamp(0.0, snap.totalDuration);
    _onSeek(target);
  }

  Future<void> _pickSpeed() async {
    _nudgeHideTimer();
    final current = widget.controller.playbackSpeed;
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in _speeds)
              ListTile(
                leading: Icon(
                  s == current ? Icons.check : null,
                  color: Colors.white,
                ),
                title: Text(
                  '${s}x',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.of(ctx).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await widget.controller.setPlaybackSpeed(picked);
      if (mounted) setState(() {}); // refresh speed label
    }
    _nudgeHideTimer();
  }

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
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _OverlayControls(
                      isPlaying: snap.isPlaying,
                      onPlayPause: () {
                        _nudgeHideTimer();
                        if (snap.isPlaying) {
                          widget.controller.pause();
                        } else {
                          widget.controller.play();
                        }
                      },
                      onSkipBack: () => _skipBy(-10, snap),
                      onSkipForward: () => _skipBy(30, snap),
                      onPickSpeed: _pickSpeed,
                      currentSpeed: widget.controller.playbackSpeed,
                      isFullScreen: widget.isFullScreen,
                      onToggleFullScreen: () {
                        _nudgeHideTimer();
                        widget.onToggleFullScreen();
                      },
                      // In fullscreen, the scrub bar is overlaid at the bottom
                      // of the video so it auto-hides with the rest of the
                      // controls.
                      bottomBar: widget.isFullScreen
                          ? _buildScrubBar(snap, forOverlay: true)
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

        return ColoredBox(
          color: Colors.black,
          // In fullscreen the parent Expanded gives us bounded height, so we
          // must use mainAxisSize.max to fill it and let Expanded(video) share
          // the space.  In non-fullscreen, min is correct so the column wraps
          // the AspectRatio player tightly.
          child: Column(
            mainAxisSize: widget.isFullScreen
                ? MainAxisSize.max
                : MainAxisSize.min,
            children: [
              if (widget.isFullScreen)
                Expanded(child: Center(child: player))
              else ...[
                player,
                // Persistent scrub bar below the player (inline mode only).
                _buildScrubBar(snap, forOverlay: false),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildScrubBar(PlaybackSnapshot snap, {required bool forOverlay}) {
    // Collect segment start times for dividers, skipping the first (always 0).
    final boundaries = widget.controller.schedule
        .map((e) => e.globalStartTime)
        .where((t) => t > 0)
        .toList();

    // While a seek is in flight, pin the displayed position to the target so
    // the thumb doesn't briefly jump to a segment boundary before settling.
    final target = _pendingSeekTarget;
    if (_scrubbing && target != null) {
      if ((snap.globalPosition - target).abs() < 0.5) {
        // Snapshot has converged — stop pinning.
        _scrubbing = false;
        _pendingSeekTarget = null;
      }
    }
    final displayPosition = (_scrubbing && target != null)
        ? target
        : snap.globalPosition;

    final bar = UnifiedScrubBar(
      position: displayPosition,
      duration: snap.totalDuration,
      segmentBoundaries: boundaries,
      onSeekStart: () {
        _nudgeHideTimer();
        setState(() => _scrubbing = true);
      },
      onSeekEnd: _nudgeHideTimer,
      onSeek: _onSeek,
    );

    return ColoredBox(
      // Overlay variant needs a translucent background so it sits legibly
      // over the video; inline variant stays solid black.
      color: forOverlay
          ? Colors.black.withValues(alpha: 0.45)
          : Colors.black,
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
        child: bar,
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _OverlayControls extends ConsumerWidget {
  const _OverlayControls({
    required this.isPlaying,
    required this.onPlayPause,
    required this.onSkipBack,
    required this.onSkipForward,
    required this.onPickSpeed,
    required this.currentSpeed,
    required this.isFullScreen,
    required this.onToggleFullScreen,
    required this.bottomBar,
  });

  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onSkipBack;
  final VoidCallback onSkipForward;
  final VoidCallback onPickSpeed;
  final double currentSpeed;
  final bool isFullScreen;
  final VoidCallback onToggleFullScreen;

  /// Optional widget painted at the bottom of the overlay (the scrub bar in
  /// fullscreen). Null in inline mode.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        // Scrim so controls are legible over light video content.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x55000000),
                Color(0x00000000),
                Color(0x55000000),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
          child: SizedBox.expand(),
        ),

        // Centre cluster: skip-back, play/pause, skip-forward.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CircleButton(
                icon: Icons.replay_10,
                iconSize: 32,
                onPressed: onSkipBack,
                tooltip: 'Back 10s',
              ),
              const SizedBox(width: 24),
              _CircleButton(
                icon: isPlaying ? Icons.pause : Icons.play_arrow,
                iconSize: 44,
                onPressed: onPlayPause,
                tooltip: isPlaying ? 'Pause' : 'Play',
              ),
              const SizedBox(width: 24),
              _CircleButton(
                icon: Icons.forward_30,
                iconSize: 32,
                onPressed: onSkipForward,
                tooltip: 'Forward 30s',
              ),
            ],
          ),
        ),

        // Top-left: speed selector.
        Positioned(
          top: 4,
          left: 4,
          child: Material(
            color: Colors.black.withValues(alpha: 0.35),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onPickSpeed,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                child: Text(
                  '${_formatSpeed(currentSpeed)}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),

        // Top-right: cast button + fullscreen toggle.
        Positioned(
          top: 4,
          right: 4,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CastButton(iconSize: 20),
              const SizedBox(width: 2),
              _CircleButton(
                icon: isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                iconSize: 22,
                minSize: 36,
                onPressed: onToggleFullScreen,
                tooltip: isFullScreen ? 'Exit fullscreen' : 'Enter fullscreen',
              ),
            ],
          ),
        ),

        // Bottom: scrub bar (fullscreen only).
        if (bottomBar != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: bottomBar!),
          ),
      ],
    );
  }

  static String _formatSpeed(double s) {
    if (s == s.roundToDouble()) return s.toStringAsFixed(0);
    return s.toString();
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.iconSize,
    required this.onPressed,
    required this.tooltip,
    this.minSize = 48,
  });

  final IconData icon;
  final double iconSize;
  final VoidCallback onPressed;
  final String tooltip;
  final double minSize;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        iconSize: iconSize,
        padding: const EdgeInsets.all(8),
        constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
