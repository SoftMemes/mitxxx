// ignore_for_file: uri_has_not_been_generated
import 'package:omnilect/features/cast/models/cast_state.dart';
import 'package:omnilect/features/cast/providers/cast_controller.dart';
import 'package:omnilect/features/cast/widgets/cast_controller_panel.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/courses/widgets/vertical_section_tile.dart';
import 'package:omnilect/features/downloads/widgets/download_button.dart';
import 'package:omnilect/features/player/models/lecture_player_state.dart';
import 'package:omnilect/features/player/models/vertical_segment.dart';
import 'package:omnilect/features/player/providers/lecture_player_provider.dart';
import 'package:omnilect/features/player/widgets/lecture_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Single-page lecture view.
///
/// Renders a stitched video player for all verticals in [sequenceId], followed
/// by a collapsible content list. The expanded section stays in sync with
/// video playback. Replaces the per-vertical `ContentScreen`.
class LectureScreen extends ConsumerStatefulWidget {
  const LectureScreen({
    required this.courseId,
    required this.sequenceId,
    super.key,
  });

  final String courseId;
  final String sequenceId;

  @override
  ConsumerState<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends ConsumerState<LectureScreen> {
  final _scrollController = ScrollController();
  final List<GlobalKey> _tileKeys = [];
  bool _isFullScreen = false;

  @override
  void dispose() {
    _scrollController.dispose();
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  void _toggleFullScreen() {
    final next = !_isFullScreen;
    setState(() => _isFullScreen = next);
    if (next) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  void _scrollToActive(int index) {
    if (index < 0 || index >= _tileKeys.length) return;
    final key = _tileKeys[index];
    final ctx = key.currentContext;
    if (ctx == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final providerArgs = (
      courseId: widget.courseId,
      sequenceId: widget.sequenceId,
    );
    final playerAsync = ref.watch(
      lecturePlayerProvider(
        courseId: providerArgs.courseId,
        sequenceId: providerArgs.sequenceId,
      ),
    );

    // Listen for active-segment changes to auto-scroll the list.
    ref
      ..listen(
        lecturePlayerProvider(
          courseId: widget.courseId,
          sequenceId: widget.sequenceId,
        ),
        (previous, next) {
          if (!next.hasValue) return;
          final prevIndex = previous?.asData?.value.activeSegmentIndex;
          final newIndex = next.requireValue.activeSegmentIndex;
          if (prevIndex != newIndex) {
            _scrollToActive(newIndex);
          }
        },
      )

      // Listen for cast session transitions.
      ..listen<CastState>(castControllerProvider, (previous, next) {
      final prevStatus = previous?.status ?? CastConnectionStatus.disconnected;
      final nextStatus = next.status;

      final playerNotifier = ref.read(
        lecturePlayerProvider(
          courseId: widget.courseId,
          sequenceId: widget.sequenceId,
        ).notifier,
      );

      if (prevStatus != CastConnectionStatus.connected &&
          nextStatus == CastConnectionStatus.connected) {
        // Just connected — load the queue and pause local playback.
        final queue = playerNotifier.castQueue;
        final globalPos =
            playerNotifier.playbackController?.snapshot.value.globalPosition ??
                0.0;

        // Compute which queue item contains the current position.
        var startIndex = 0;
        var startOffset = 0.0;
        for (var i = 0; i < queue.length; i++) {
          if (queue[i].globalStartTime <= globalPos) {
            startIndex = i;
            startOffset = globalPos - queue[i].globalStartTime;
          }
        }

        ref
            .read(castControllerProvider.notifier)
            .loadQueue(queue, startIndex: startIndex, startOffset: startOffset);
        playerNotifier.pause();
      }

      if (prevStatus == CastConnectionStatus.connected &&
          nextStatus == CastConnectionStatus.disconnected) {
        // Just disconnected — resume local player at last cast position, paused.
        final lastPos = previous?.globalPosition ?? 0.0;
        playerNotifier.seekGlobal(lastPos);
        // Do NOT call play() — per spec: fall back paused.
      }
    });

    return Scaffold(
      backgroundColor: _isFullScreen ? Colors.black : null,
      appBar: _isFullScreen
          ? null
          : AppBar(
              title: playerAsync.maybeWhen(
                data: (s) => Text(
                  s.segments.isNotEmpty
                      ? s.segments[s.activeSegmentIndex].title
                      : 'Lecture',
                  overflow: TextOverflow.ellipsis,
                ),
                orElse: () => const Text('Lecture'),
              ),
              actions: [
                DownloadButton(
                  courseId: widget.courseId,
                  sequenceId: widget.sequenceId,
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: playerAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorBody(
          message: error.toString(),
          onRetry: () => ref.invalidate(
            lecturePlayerProvider(
              courseId: widget.courseId,
              sequenceId: widget.sequenceId,
            ),
          ),
        ),
        data: _buildBody,
      ),
    );
  }

  Widget _buildBody(LecturePlayerState lectureState) {
    // Grow tile-key list to match segment count.
    while (_tileKeys.length < lectureState.segments.length) {
      _tileKeys.add(GlobalKey());
    }

    final notifier = ref.read(
      lecturePlayerProvider(
        courseId: widget.courseId,
        sequenceId: widget.sequenceId,
      ).notifier,
    );

    final playbackController = notifier.playbackController;

    // If there's no video at all, just show the content list.
    if (playbackController == null) {
      return _NoVideoBody(
        segments: lectureState.segments,
        tileKeys: _tileKeys,
        activeIndex: lectureState.activeSegmentIndex,
        onTileTap: notifier.selectSegment,
      );
    }

    // While a cast session is active, replace the video player with the cast
    // controller panel.
    final castState = ref.watch(castControllerProvider);
    if (castState.isConnected) {
      return const CastControllerPanel();
    }

    // Error overlay over the video area.
    if (lectureState.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(lectureState.errorMessage!),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: notifier.retry,
            ),
          ),
        );
      });
    }

    return Column(
      children: [
        // In fullscreen the player must fill all remaining height, so wrap it
        // in Expanded to give it a bounded constraint.  The player's own inner
        // Column then uses mainAxisSize.max and its Expanded(video) child can
        // share that bounded space with the scrub bar.
        if (_isFullScreen)
          Expanded(
            child: LectureVideoPlayer(
              controller: playbackController,
              isFullScreen: true,
              onToggleFullScreen: _toggleFullScreen,
              onSeek: notifier.seekGlobal,
              onScrubStart: notifier.onScrubStart,
              onScrubEnd: notifier.onScrubEnd,
            ),
          )
        else
          LectureVideoPlayer(
            controller: playbackController,
            isFullScreen: false,
            onToggleFullScreen: _toggleFullScreen,
            onSeek: notifier.seekGlobal,
            onScrubStart: notifier.onScrubStart,
            onScrubEnd: notifier.onScrubEnd,
          ),

        // Content list — hidden in fullscreen.
        if (!_isFullScreen) ...[
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: lectureState.segments.length,
              itemBuilder: (context, i) {
                final seg = lectureState.segments[i];
                return VerticalSectionTile(
                  key: _tileKeys[i],
                  segment: seg,
                  isExpanded: i == lectureState.activeSegmentIndex,
                  onTap: () => notifier.selectSegment(i),
                );
              },
            ),
          ),

          // Completion banner.
          if (lectureState.isComplete)
            _CompletionBanner(
              courseId: widget.courseId,
              sequenceId: widget.sequenceId,
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _NoVideoBody extends StatelessWidget {
  const _NoVideoBody({
    required this.segments,
    required this.tileKeys,
    required this.activeIndex,
    required this.onTileTap,
  });

  final List<VerticalSegment> segments;
  final List<GlobalKey> tileKeys;
  final int activeIndex;
  final void Function(int) onTileTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: segments.length,
      itemBuilder: (context, i) => VerticalSectionTile(
        key: tileKeys[i],
        segment: segments[i],
        isExpanded: i == activeIndex,
        onTap: () => onTileTap(i),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('Could not load lecture'),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Banner shown when all video segments have finished playing.
class _CompletionBanner extends ConsumerWidget {
  const _CompletionBanner({
    required this.courseId,
    required this.sequenceId,
  });

  final String courseId;
  final String sequenceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outlineAsync =
        ref.watch(courseOutlineProvider(courseId: courseId));

    final nextSequenceId = outlineAsync.maybeWhen(
      data: (outline) {
        // Flatten all sequence IDs in order across sections.
        final allIds = outline.outline.sections
            .expand((s) => s.sequenceIds)
            .toList();
        final idx = allIds.indexOf(sequenceId);
        if (idx < 0 || idx + 1 >= allIds.length) return null;
        return allIds[idx + 1];
      },
      orElse: () => null,
    );

    return Container(
      color: Theme.of(context).colorScheme.primaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Icon(
              Icons.check_circle,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Lecture complete',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            if (nextSequenceId != null)
              FilledButton(
                onPressed: () => context.pushReplacement(
                  '/course/$courseId/sequence/$nextSequenceId',
                ),
                child: const Text('Next lecture'),
              ),
          ],
        ),
      ),
    );
  }
}
