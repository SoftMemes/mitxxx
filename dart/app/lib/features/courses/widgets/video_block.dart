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
/// Chewie provides a polished control bar with playback-speed menu, seek
/// scrubber, and a native fullscreen mode, so we don't need a custom
/// fullscreen screen any more.
class VideoBlock extends ConsumerStatefulWidget {
  const VideoBlock({
    required this.video,
    super.key,
    this.autoPlay = false,
    this.autoFullScreen = false,
    this.onCompleted,
  });

  final ParsedVideoBlock video;

  /// If true the video starts playing as soon as it is initialized.
  final bool autoPlay;

  /// If true the player enters Chewie's fullscreen mode as soon as it is
  /// initialized. Used to carry fullscreen state across auto-advance so
  /// the user stays in fullscreen while a sequence of videos plays through.
  final bool autoFullScreen;

  /// Fires once when the video reaches (or is within ~300ms of) its end.
  /// The bool argument is true if the player was in fullscreen at the
  /// moment of completion, letting the parent restore that state on the
  /// next video. Used by the parent to implement auto-advance.
  final ValueChanged<bool>? onCompleted;

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

      if (widget.autoFullScreen) {
        // Enter fullscreen before starting playback so the transition
        // into fullscreen is seamless when auto-advancing across videos.
        chewie.enterFullScreen();
      }
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
      // If we're in Chewie's fullscreen route when the video ends, the
      // overlay obscures the PageView transition that the parent triggers
      // from onCompleted. On iOS the lingering AVPlayerViewController-style
      // fullscreen also blocks the next video's autoplay — the user sees
      // the replay icon on the finished video and, only after manually
      // exiting fullscreen, lands on the next page with autoplay never
      // having fired. Drop out of fullscreen first so the transition is
      // visible and the next controller can take over cleanly; the parent
      // uses the captured wasFullScreen flag to re-enter fullscreen on the
      // next video so the fullscreen experience persists across advances.
      final wasFullScreen = _chewieController?.isFullScreen ?? false;
      if (wasFullScreen) {
        _chewieController!.exitFullScreen();
      }
      widget.onCompleted?.call(wasFullScreen);
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

    return AspectRatio(
      aspectRatio: _videoController!.value.aspectRatio,
      child: Chewie(controller: _chewieController!),
    );
  }
}
