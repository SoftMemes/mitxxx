import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:emajtee/features/downloads/providers/scope_download_provider.dart';
import 'package:emajtee/features/downloads/providers/video_download_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Icon-only download button that reflects the aggregate download state for
/// a scope (course / sequence / vertical).
///
/// Pass [sequenceId] to scope to a sequence, [verticalId] to scope to a
/// vertical. Omit both for course-level scope.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({
    required this.courseId,
    super.key,
    this.sequenceId,
    this.verticalId,
    this.iconSize = 24.0,
  });

  final String courseId;
  final String? sequenceId;
  final String? verticalId;
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(scopeDownloadStateProvider(
      courseId: courseId,
      sequenceId: sequenceId,
      verticalId: verticalId,
    ));

    return stateAsync.when(
      loading: () => SizedBox(
        width: iconSize,
        height: iconSize,
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, _) => Icon(Icons.error_outline, size: iconSize),
      data: (state) {
        if (state.isEmpty) return const SizedBox.shrink();
        return _ButtonForState(
          state: state,
          iconSize: iconSize,
          onDownload: () => ref.read(videoDownloadManagerProvider).enqueueScope(
                courseId: courseId,
                sequenceId: sequenceId,
                verticalId: verticalId,
              ),
          onDelete: () => _confirmDelete(context, ref, state),
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ScopeDownloadState state,
  ) async {
    final label = verticalId != null
        ? 'this video'
        : sequenceId != null
            ? "this sequence's videos"
            : 'all downloaded videos for this course';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove download?'),
        content: Text('Remove $label from your device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(videoDownloadManagerProvider).deleteScope(
            courseId: courseId,
            sequenceId: sequenceId,
            verticalId: verticalId,
          );
    }
  }
}

class _ButtonForState extends StatelessWidget {
  const _ButtonForState({
    required this.state,
    required this.iconSize,
    required this.onDownload,
    required this.onDelete,
  });

  final ScopeDownloadState state;
  final double iconSize;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    switch (state.status) {
      case DownloadStatus.downloading:
        return SizedBox(
          width: iconSize,
          height: iconSize,
          child: CircularProgressIndicator(
            value: state.progress > 0 ? state.progress : null,
            strokeWidth: 2,
          ),
        );

      case DownloadStatus.downloaded:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: iconSize + 8,
            minHeight: iconSize + 8,
          ),
          icon: Icon(Icons.check_circle, size: iconSize, color: Colors.green),
          tooltip: 'Downloaded — tap to remove',
          onPressed: onDelete,
        );

      case DownloadStatus.stale:
        return Stack(
          alignment: Alignment.topRight,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: iconSize + 8,
                minHeight: iconSize + 8,
              ),
              icon: Icon(Icons.download_outlined, size: iconSize),
              tooltip: 'New version available — tap to update',
              onPressed: onDownload,
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        );

      case DownloadStatus.failed:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: iconSize + 8,
            minHeight: iconSize + 8,
          ),
          icon: Icon(Icons.error_outline, size: iconSize, color: Theme.of(context).colorScheme.error),
          tooltip: 'Download failed — tap to retry',
          onPressed: onDownload,
        );

      case DownloadStatus.notDownloaded:
      case DownloadStatus.queued:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: iconSize + 8,
            minHeight: iconSize + 8,
          ),
          icon: Icon(Icons.download_outlined, size: iconSize),
          tooltip: 'Download for offline viewing',
          onPressed: onDownload,
        );
    }
  }
}
