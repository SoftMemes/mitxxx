import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/features/courses/widgets/html_block.dart';
import 'package:omnilect/features/downloads/widgets/download_button.dart';
import 'package:omnilect/features/player/providers/ocw_lecture_player_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Single-lecture screen for an OCW course. OCW lectures are one video per
/// page (no stitching, no xblock hierarchy) so the UI is a slimmer cousin of
/// the MITx `LectureScreen`: a single video player on top (or "not available"
/// state) with a resource tile below, rendered through the same `HtmlBlock`
/// as MITx content.
class OcwLectureScreen extends ConsumerWidget {
  const OcwLectureScreen({
    required this.courseId,
    required this.lectureSlug,
    super.key,
  });

  final String courseId;
  final String lectureSlug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args =
        OcwLectureArgs(courseId: courseId, lectureSlug: lectureSlug);
    final async = ref.watch(ocwLecturePlayerProvider(args));
    return Scaffold(
      appBar: AppBar(
        title: async.maybeWhen(
          data: (s) => Text(s.lecture.title, overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Lecture'),
        ),
        actions: [
          DownloadButton(
            courseId: courseId,
            verticalId: '$courseId/$lectureSlug',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load lecture: $e'),
          ),
        ),
        data: (state) => _OcwLectureBody(state: state, courseId: courseId),
      ),
    );
  }
}

class _OcwLectureBody extends StatelessWidget {
  const _OcwLectureBody({required this.state, required this.courseId});

  final OcwLectureViewState state;
  final String courseId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (state.hasVideo)
          _OcwVideoArea(uri: state.playableUri)
        else
          _NoVideoArea(
            fallbackUrl:
                'https://ocw.mit.edu/courses/${courseId.substring('ocw:'.length)}/resources/${state.lecture.slug}/',
          ),
        Expanded(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: state.safeResourcesHtml.trim().isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No additional content for this lecture.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  )
                : HtmlBlock(html: state.safeResourcesHtml),
          ),
        ),
      ],
    );
  }
}

class _NoVideoArea extends StatelessWidget {
  const _NoVideoArea({required this.fallbackUrl});

  final String fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_off_outlined,
                    size: 48, color: cs.onSurfaceVariant),
                const SizedBox(height: 12),
                Text(
                  'Video not available in the app',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => unawaited(launchUrl(
                    Uri.parse(fallbackUrl),
                    mode: LaunchMode.externalApplication,
                  )),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open on ocw.mit.edu'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OcwVideoArea extends StatefulWidget {
  const _OcwVideoArea({required this.uri});

  final Uri? uri;

  @override
  State<_OcwVideoArea> createState() => _OcwVideoAreaState();
}

class _OcwVideoAreaState extends State<_OcwVideoArea> {
  VideoPlayerController? _controller;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(covariant _OcwVideoArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      unawaited(_controller?.dispose());
      _controller = null;
      _initController();
    }
  }

  Future<void> _initController() async {
    final uri = widget.uri;
    if (uri == null) return;
    final vpc = uri.scheme == 'file'
        ? VideoPlayerController.file(File(uri.toFilePath()))
        : VideoPlayerController.networkUrl(uri);
    await vpc.initialize();
    if (!mounted) {
      await vpc.dispose();
      return;
    }
    setState(() => _controller = vpc);
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vpc = _controller;
    if (vpc == null || !vpc.value.isInitialized) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: vpc.value.aspectRatio,
      child: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoPlayer(vpc),
            if (_showControls) _VideoControlsOverlay(controller: vpc),
            Align(
              alignment: Alignment.bottomCenter,
              child: VideoProgressIndicator(
                vpc,
                allowScrubbing: true,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoControlsOverlay extends StatelessWidget {
  const _VideoControlsOverlay({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black26,
      child: Center(
        child: IconButton(
          iconSize: 64,
          color: Colors.white,
          onPressed: () {
            if (controller.value.isPlaying) {
              controller.pause();
            } else {
              controller.play();
            }
          },
          icon: Icon(
            controller.value.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled,
          ),
        ),
      ),
    );
  }
}
