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
        width: iconSize + 8,
        height: iconSize + 8,
        child: Center(
          child: SizedBox(
            width: iconSize,
            height: iconSize,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
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
    final isActive = state.isDownloading;
    final label = verticalId != null
        ? 'this video'
        : sequenceId != null
            ? "this sequence's videos"
            : isActive
                ? 'all downloads for this course'
                : 'all downloaded videos for this course';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isActive ? 'Cancel download?' : 'Remove download?'),
        content: Text(
          isActive
              ? 'Cancel and remove $label?'
              : 'Remove $label from your device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isActive ? 'Cancel download' : 'Remove'),
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

class _ButtonForState extends StatefulWidget {
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
  State<_ButtonForState> createState() => _ButtonForStateState();
}

class _ButtonForStateState extends State<_ButtonForState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.iconSize;
    final boxSize = iconSize + 8;

    switch (widget.state.status) {
      case DownloadStatus.downloading:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          tooltip: 'Downloading — tap to cancel',
          onPressed: widget.onDelete,
          icon: SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              value: widget.state.progress > 0 ? widget.state.progress : null,
              strokeWidth: 2,
            ),
          ),
        );

      case DownloadStatus.downloaded:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          icon: Icon(Icons.check_circle, size: iconSize, color: Colors.green),
          tooltip: 'Downloaded — tap to remove',
          onPressed: widget.onDelete,
        );

      case DownloadStatus.stale:
        return Stack(
          alignment: Alignment.topRight,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  BoxConstraints(minWidth: boxSize, minHeight: boxSize),
              icon: Icon(Icons.download_outlined, size: iconSize),
              tooltip: 'New version available — tap to update',
              onPressed: widget.onDownload,
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
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          icon: Icon(
            Icons.error_outline,
            size: iconSize,
            color: Theme.of(context).colorScheme.error,
          ),
          tooltip: 'Download failed — tap to retry',
          onPressed: widget.onDownload,
        );

      case DownloadStatus.pending:
        return SizedBox(
          width: boxSize,
          height: boxSize,
          child: Center(
            child: Icon(Icons.hourglass_top_outlined, size: iconSize),
          ),
        );

      case DownloadStatus.queued:
        // Counter-clockwise spinner — in background_downloader holding queue.
        return SizedBox(
          width: boxSize,
          height: boxSize,
          child: Center(
            child: RotationTransition(
              turns: Tween<double>(begin: 0, end: -1).animate(_spinController),
              child: SizedBox(
                width: iconSize,
                height: iconSize,
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  value: 0.25,
                ),
              ),
            ),
          ),
        );

      case DownloadStatus.notDownloaded:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          icon: Icon(Icons.download_outlined, size: iconSize),
          tooltip: 'Download for offline viewing',
          onPressed: widget.onDownload,
        );
    }
  }
}
