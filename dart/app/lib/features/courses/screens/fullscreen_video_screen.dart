import 'dart:async';
import 'dart:io';

import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

/// Result returned when the fullscreen player is dismissed.
class FullscreenResult {
  const FullscreenResult({
    required this.closedEarly,
    required this.verticalIndex,
    this.videoIndex,
  });

  /// True if the user closed the player before the video completed.
  final bool closedEarly;

  /// The vertical index the player was on when dismissed.
  final int verticalIndex;

  /// The video index within the vertical (only meaningful when [closedEarly]).
  final int? videoIndex;
}

class FullscreenVideoScreen extends ConsumerStatefulWidget {
  const FullscreenVideoScreen({
    super.key,
    required this.sequence,
    required this.initialVerticalIndex,
    required this.initialVideoIndex,
  });

  final SequenceDetail sequence;
  final int initialVerticalIndex;
  final int initialVideoIndex;

  @override
  ConsumerState<FullscreenVideoScreen> createState() =>
      _FullscreenVideoScreenState();
}

class _FullscreenVideoScreenState
    extends ConsumerState<FullscreenVideoScreen> {
  late int _verticalIndex;
  late int _videoIndex;
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;
  bool _completed = false;
  bool _showControls = true;
  Timer? _hideControlsTimer;

  @override
  void initState() {
    super.initState();
    _verticalIndex = widget.initialVerticalIndex;
    _videoIndex = widget.initialVideoIndex;
    // Force landscape.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initController();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    _hideControlsTimer?.cancel();
    // Restore portrait on exit.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _initController() async {
    final video = _currentVideo();
    if (video == null) {
      setState(() => _hasError = true);
      return;
    }

    final url = video.mp4Url ?? video.hlsUrl;
    if (url == null) {
      setState(() => _hasError = true);
      return;
    }

    final prev = _controller;

    // Prefer locally downloaded file over streaming.
    VideoPlayerController newController;
    if (video.mp4Url != null) {
      final db = ref.read(appDatabaseProvider);
      final downloaded = await db.getDownloadedVideo(video.mp4Url!);
      if (downloaded != null &&
          downloaded.status == DownloadStatus.downloaded.name &&
          downloaded.localFilePath.isNotEmpty &&
          File(downloaded.localFilePath).existsSync()) {
        newController = VideoPlayerController.file(
          File(downloaded.localFilePath),
        );
      } else {
        newController = VideoPlayerController.networkUrl(Uri.parse(url));
      }
    } else {
      newController = VideoPlayerController.networkUrl(Uri.parse(url));
    }
    try {
      await newController.initialize();
      if (!mounted) {
        await newController.dispose();
        return;
      }
      newController.addListener(_onControllerUpdate);
      await prev?.dispose();
      setState(() {
        _controller = newController;
        _initialized = true;
        _hasError = false;
        _completed = false;
      });
      await newController.play();
      _scheduleHideControls();
    } catch (_) {
      await newController.dispose();
      if (mounted) setState(() => _hasError = true);
    }
  }

  ParsedVideoBlock? _currentVideo() {
    final item = widget.sequence.items[_verticalIndex];
    final xblock = ref
        .read(xblockContentProvider(blockId: item.id))
        .asData?.value;
    if (xblock == null || _videoIndex >= xblock.videos.length) return null;
    return xblock.videos[_videoIndex];
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final c = _controller;
    if (c == null) return;
    if (!_completed &&
        c.value.isInitialized &&
        !c.value.isPlaying &&
        c.value.position >= c.value.duration - const Duration(milliseconds: 300)) {
      setState(() => _completed = true);
      _onVideoCompleted();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _onVideoCompleted() {
    final next = _findNextVideo();
    if (next == null) {
      // No more videos — pop with completion result.
      if (mounted) {
        Navigator.of(context).pop(FullscreenResult(
          closedEarly: false,
          verticalIndex: _verticalIndex,
        ));
      }
      return;
    }
    // Auto-advance to next video.
    setState(() {
      _verticalIndex = next.$1;
      _videoIndex = next.$2;
      _initialized = false;
      _completed = false;
    });
    _initController();
  }

  /// Finds the next video in the sequence after the current position.
  /// Returns (verticalIndex, videoIndex) or null if none.
  (int, int)? _findNextVideo() {
    // Check remaining videos in current vertical.
    final currentItem = widget.sequence.items[_verticalIndex];
    final currentXblock = ref
        .read(xblockContentProvider(blockId: currentItem.id))
        .asData?.value;
    if (currentXblock != null &&
        _videoIndex + 1 < currentXblock.videos.length) {
      return (_verticalIndex, _videoIndex + 1);
    }

    // Check subsequent verticals.
    for (var vi = _verticalIndex + 1;
        vi < widget.sequence.items.length;
        vi++) {
      final item = widget.sequence.items[vi];
      final xblock =
          ref.read(xblockContentProvider(blockId: item.id)).asData?.value;
      if (xblock != null && xblock.videos.isNotEmpty) {
        return (vi, 0);
      }
    }
    return null;
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  void _pop() {
    Navigator.of(context).pop(FullscreenResult(
      closedEarly: true,
      verticalIndex: _verticalIndex,
      videoIndex: _videoIndex,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video.
            if (_hasError)
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, color: Colors.white, size: 48),
                    SizedBox(height: 8),
                    Text('Video could not be loaded',
                        style: TextStyle(color: Colors.white)),
                  ],
                ),
              )
            else if (!_initialized || _controller == null)
              const Center(child: CircularProgressIndicator(color: Colors.white))
            else
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              ),

            // Controls overlay (fades in/out).
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: _ControlsOverlay(
                  controller: _controller,
                  onBack: _pop,
                  onPlayPause: () {
                    if (_controller == null) return;
                    if (_controller!.value.isPlaying) {
                      _controller!.pause();
                    } else {
                      _controller!.play();
                      _scheduleHideControls();
                    }
                    setState(() {});
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.onBack,
    required this.onPlayPause,
  });

  final VideoPlayerController? controller;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) {
    final isPlaying = controller?.value.isPlaying ?? false;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x88000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0x88000000),
          ],
        ),
      ),
      child: Column(
        children: [
          // Top bar — back button.
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: onBack,
                ),
              ],
            ),
          ),
          // Centre play/pause.
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 64,
                icon: Icon(
                  isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                onPressed: onPlayPause,
              ),
            ),
          ),
          // Bottom progress bar.
          if (controller != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
              child: VideoProgressIndicator(
                controller!,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Color(0x55ffffff),
                  backgroundColor: Color(0x33ffffff),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
