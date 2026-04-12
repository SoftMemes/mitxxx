import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoBlock extends StatefulWidget {
  const VideoBlock({super.key, required this.video});

  final ParsedVideoBlock video;

  @override
  State<VideoBlock> createState() => _VideoBlockState();
}

class _VideoBlockState extends State<VideoBlock> {
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

    try {
      final controller =
          VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      if (mounted) {
        setState(() {
          _controller = controller;
          _initialized = true;
        });
      } else {
        await controller.dispose();
      }
    } catch (_) {
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
                  setState(() => _hasError = false);
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
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: const Center(child: CircularProgressIndicator()),
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
              _VideoControls(controller: _controller!),
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
  const _VideoControls({required this.controller});

  final VideoPlayerController controller;

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
    return GestureDetector(
      onTap: isPlaying
          ? () => widget.controller.pause()
          : () => widget.controller.play(),
      child: Container(
        color: Colors.transparent,
        child: Center(
          child: Icon(
            isPlaying ? Icons.pause_circle : Icons.play_circle,
            size: 64,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}
