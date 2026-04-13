import 'dart:io';

import 'package:emajtee/core/network/connectivity_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

class VideoBlock extends ConsumerStatefulWidget {
  const VideoBlock({
    required this.video,
    required this.onFullscreen,
    super.key,
  });

  final ParsedVideoBlock video;

  /// Called when the user taps the fullscreen button.
  final VoidCallback onFullscreen;

  @override
  ConsumerState<VideoBlock> createState() => _VideoBlockState();
}

class _VideoBlockState extends ConsumerState<VideoBlock> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;

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
      if (mounted) {
        setState(() {
          _controller = controller;
          _initialized = true;
        });
      } else {
        await controller.dispose();
      }
    } on Object catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _hasError = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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
      return const Card(
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.wifi_off, color: Colors.grey),
              SizedBox(width: 8),
              Expanded(
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
              const Icon(Icons.error_outline, color: Colors.grey),
              const SizedBox(width: 8),
              const Expanded(child: Text('Video could not be loaded')),
              TextButton(
                onPressed: () {
                  setState(() {
                    _hasError = false;
                    _initialized = false;
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

    if (!_initialized || _controller == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: _controller!.value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              VideoPlayer(_controller!),
              _VideoControls(
                controller: _controller!,
                onFullscreen: widget.onFullscreen,
              ),
            ],
          ),
        ),
        VideoProgressIndicator(
          _controller!,
          allowScrubbing: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
      ],
    );
  }
}

class _VideoControls extends StatefulWidget {
  const _VideoControls({
    required this.controller,
    required this.onFullscreen,
  });

  final VideoPlayerController controller;
  final VoidCallback onFullscreen;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = widget.controller.value.isPlaying;
    return ColoredBox(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Centre play/pause.
          Center(
            child: GestureDetector(
              onTap: isPlaying
                  ? () => widget.controller.pause()
                  : () => widget.controller.play(),
              child: Icon(
                isPlaying ? Icons.pause_circle : Icons.play_circle,
                size: 64,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ),
          // Fullscreen button in bottom-right.
          Positioned(
            bottom: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.fullscreen, color: Colors.white),
              tooltip: 'Full screen',
              onPressed: widget.onFullscreen,
            ),
          ),
        ],
      ),
    );
  }
}
