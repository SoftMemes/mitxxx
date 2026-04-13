import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:emajtee/features/downloads/providers/scope_download_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Inline "3 / 10 videos  ■■■□□□□" progress bar for a download scope.
/// Hidden when there are no videos in scope or when none are downloaded.
class DownloadProgressBar extends ConsumerWidget {
  const DownloadProgressBar({
    super.key,
    required this.courseId,
    this.sequenceId,
    this.verticalId,
  });

  final String courseId;
  final String? sequenceId;
  final String? verticalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(scopeDownloadStateProvider(
      courseId: courseId,
      sequenceId: sequenceId,
      verticalId: verticalId,
    ));

    return stateAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (state) {
        if (state.isEmpty || state.downloaded == 0 && !state.isDownloading) {
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
    final label = state.isFullyDownloaded
        ? 'All ${state.total} videos downloaded'
        : '${state.downloaded} / ${state.total} videos';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              value: state.progress,
              minHeight: 4,
              color: state.isFullyDownloaded
                  ? Colors.green
                  : theme.colorScheme.primary,
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
