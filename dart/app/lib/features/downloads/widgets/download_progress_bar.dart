import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:emajtee/features/downloads/providers/scope_download_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Inline "3 / 10 lectures  ■■■□□□□" (or "videos") progress bar.
/// Hidden when there are no videos in scope or when none are downloaded.
///
/// Set [useLectureCount] to count sequences (lectures) as the unit rather
/// than individual video clips — appropriate for the course overview screen.
class DownloadProgressBar extends ConsumerWidget {
  const DownloadProgressBar({
    required this.courseId,
    super.key,
    this.sequenceId,
    this.verticalId,
    this.useLectureCount = false,
  });

  final String courseId;
  final String? sequenceId;
  final String? verticalId;

  /// When true, progress counts lectures (sequences) rather than clips.
  final bool useLectureCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = useLectureCount
        ? ref.watch(courseLectureDownloadStateProvider(courseId: courseId))
        : ref.watch(scopeDownloadStateProvider(
            courseId: courseId,
            sequenceId: sequenceId,
            verticalId: verticalId,
          ));

    return stateAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (state) {
        // Hide when nothing is in progress (including when fully complete).
        if (state.isEmpty || !state.isDownloading) {
          return const SizedBox.shrink();
        }
        return _ProgressBar(state: state);
      },
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.state});
  final ScopeDownloadState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = '${state.downloaded} / ${state.requested}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: state.requestedProgress,
              minHeight: 4,
              color: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
