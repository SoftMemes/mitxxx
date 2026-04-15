import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:emajtee/core/network/connectivity_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

/// Inline video player built on top of `chewie`.
///
/// Fullscreen is managed at the screen level (see `ContentScreen`) rather
/// than by Chewie itself. Chewie's own fullscreen feature is disabled via
/// `allowFullScreen: false`, and a small overlay button drives the
/// screen-level toggle. This keeps fullscreen state persistent across
/// auto-advance between videos — switching pages inside a PageView no
/// longer tears down and recreates a per-controller fullscreen route.
class VideoBlock extends ConsumerStatefulWidget {
  const VideoBlock({
    required this.video,
    required this.isFullScreen,
    required this.onToggleFullScreen,
    super.key,
    this.autoPlay = false,
    this.onCompleted,
  });

  final ParsedVideoBlock video;

  /// If true the video starts playing as soon as it is initialized.
  final bool autoPlay;

  /// Whether the host screen is currently rendering in fullscreen mode.
  /// Drives the icon on the custom fullscreen toggle and the layout
  /// (fill-parent vs. inline aspect ratio).
  final bool isFullScreen;

  /// Fires when the user taps the fullscreen toggle.
  final VoidCallback onToggleFullScreen;

  /// Fires once when the video reaches (or is within ~300ms of) its end.
  /// Used by the parent to implement auto-advance.
  final VoidCallback? onCompleted;

  @override
  ConsumerState<VideoBlock> createState() => _VideoBlockState();
}

class _VideoBlockState extends ConsumerState<VideoBlock> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _initialized = false;
  bool _hasError = false;
  bool _completedFired = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    final url = widget.video.mp4Url ?? widget.video.hlsUrl;
    if (url == null) {
      setState(() => _hasError = true);
      return;
    }

    // Prefer locally downloaded file over streaming.
    VideoPlayerController? controller;
    if (widget.video.mp4Url != null) {
      final db = ref.read(appDatabaseProvider);
      final downloaded = await db.getDownloadedVideo(widget.video.mp4Url!);
      if (downloaded != null &&
          downloaded.status == DownloadStatus.downloaded.name &&
          downloaded.localFilePath.isNotEmpty &&
          File(downloaded.localFilePath).existsSync()) {
        controller = VideoPlayerController.file(
          File(downloaded.localFilePath),
        );
      }
    }

    controller ??= VideoPlayerController.networkUrl(Uri.parse(url));

    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      final chewie = ChewieController(
        videoPlayerController: controller,
        aspectRatio: controller.value.aspectRatio,
        autoInitialize: true,
        // Disable Chewie's own fullscreen — we manage fullscreen at the
        // screen level instead (see VideoBlock docstring).
        allowFullScreen: false,
        playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0],
        materialProgressColors: ChewieProgressColors(
          playedColor: Theme.of(context).colorScheme.primary,
          handleColor: Theme.of(context).colorScheme.primary,
          backgroundColor: Colors.black26,
          bufferedColor: Colors.white30,
        ),
      );

      controller.addListener(_onControllerUpdate);

      setState(() {
        _videoController = controller;
        _chewieController = chewie;
        _initialized = true;
      });

      if (widget.autoPlay) {
        await controller.play();
      }
    } on Object catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _hasError = true);
    }
  }

  void _onControllerUpdate() {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    if (_completedFired) return;
    if (c.value.duration == Duration.zero) return;

    final remaining = c.value.duration - c.value.position;
    if (remaining <= const Duration(milliseconds: 300) && !c.value.isPlaying) {
      _completedFired = true;
      widget.onCompleted?.call();
    }
  }

  @override
  void dispose() {
    _videoController?.removeListener(_onControllerUpdate);
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Offline check — default to online if the stream hasn't emitted yet.
    final isOnline = ref.watch(isOnlineProvider).when(
          data: (v) => v,
          loading: () => true,
          error: (_, _) => true,
        );

    // Show offline-not-downloaded card only when offline AND no local file.
    if (!isOnline && !_initialized) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.wifi_off, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Video not available offline — download it first',
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasError) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              const Expanded(child: Text('Video could not be loaded')),
              TextButton(
                onPressed: () {
                  setState(() {
                    _hasError = false;
                    _initialized = false;
                    _completedFired = false;
                  });
                  _initController();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized || _chewieController == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final player = AspectRatio(
      aspectRatio: _videoController!.value.aspectRatio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Chewie(controller: _chewieController!),
          Positioned(
            top: 4,
            right: 4,
            child: _FullScreenToggleButton(
              isFullScreen: widget.isFullScreen,
              onPressed: widget.onToggleFullScreen,
            ),
          ),
        ],
      ),
    );

    if (widget.isFullScreen) {
      // Fill the available screen area and letterbox with black.
      return ColoredBox(
        color: Colors.black,
        child: Center(child: player),
      );
    }

    return player;
  }
}

/// Small semi-transparent icon button overlaid on the video to toggle
/// screen-level fullscreen. Placed above Chewie's own controls in the
/// Stack so it remains tappable while Chewie's controls are visible.
class _FullScreenToggleButton extends StatelessWidget {
  const _FullScreenToggleButton({
    required this.isFullScreen,
    required this.onPressed,
  });

  final bool isFullScreen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
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
        onPressed: onPressed,
      ),
    );
  }
}
