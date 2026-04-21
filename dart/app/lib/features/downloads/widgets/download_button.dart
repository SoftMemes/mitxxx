import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/features/downloads/models/download_status.dart';
import 'package:omnilect/features/downloads/providers/scope_download_provider.dart';
import 'package:omnilect/features/downloads/providers/video_download_manager.dart';

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

    // Match the spinner to the ambient icon color so it stays visible on any
    // background — in an AppBar the IconTheme resolves to the foreground
    // (white on a red bar); in list tiles it falls back to the theme primary.
    final spinnerColor =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;

    return stateAsync.when(
      loading: () => SizedBox(
        width: iconSize + 8,
        height: iconSize + 8,
        child: Center(
          child: SizedBox(
            width: iconSize,
            height: iconSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: spinnerColor,
            ),
          ),
        ),
      ),
      error: (_, _) => Icon(Icons.error_outline, size: iconSize),
      data: (state) {
        if (state.isEmpty) return const SizedBox.shrink();

        // Course-level, some-but-not-all downloaded, nothing in flight: show
        // a split "half-done" icon that opens a download-all / remove-all
        // dialog rather than silently re-downloading the remainder.
        final isCourseScope = sequenceId == null && verticalId == null;
        final isPartialCourse = isCourseScope &&
            state.downloaded > 0 &&
            state.downloaded < state.total &&
            state.status == DownloadStatus.notDownloaded;

        if (isPartialCourse) {
          return _PartialCourseButton(
            iconSize: iconSize,
            onTap: () => _confirmPartialCourse(context, ref),
          );
        }

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

  Future<void> _confirmPartialCourse(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final action = await showDialog<_PartialCourseAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Partially downloaded'),
        content: const Text(
          'Some videos for this course are downloaded. '
          'Download the remaining videos, or remove all downloads?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_PartialCourseAction.remove),
            child: const Text('Remove all'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(_PartialCourseAction.download),
            child: const Text('Download all'),
          ),
        ],
      ),
    );

    final manager = ref.read(videoDownloadManagerProvider);
    switch (action) {
      case _PartialCourseAction.download:
        await manager.enqueueScope(courseId: courseId);
      case _PartialCourseAction.remove:
        await manager.deleteScope(courseId: courseId);
      case null:
        break;
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ScopeDownloadState state,
  ) async {
    final isActive = state.isDownloading || state.isPending;
    final isCourseScope = sequenceId == null && verticalId == null;

    // Course-level button mid-download: offer to stop without wiping what's
    // already on disk, as a separate choice from deleting everything.
    if (isCourseScope && isActive) {
      final action = await showDialog<_CourseDownloadingAction>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Downloading…'),
          content: const Text(
            'Stop downloading and keep the videos already downloaded, '
            'or delete all downloads for this course?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep downloading'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_CourseDownloadingAction.stop),
              child: const Text('Stop downloading'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_CourseDownloadingAction.deleteAll),
              child: const Text('Delete all'),
            ),
          ],
        ),
      );

      final manager = ref.read(videoDownloadManagerProvider);
      switch (action) {
        case _CourseDownloadingAction.stop:
          await manager.stopDownloadsInScope(courseId: courseId);
        case _CourseDownloadingAction.deleteAll:
          await manager.deleteScope(courseId: courseId);
        case null:
          break;
      }
      return;
    }

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

enum _CourseDownloadingAction { stop, deleteAll }

enum _PartialCourseAction { download, remove }

/// Split-state icon shown for a course whose videos are partially downloaded:
/// top half mirrors the solid-green "downloaded" disc, bottom half is the
/// arrowhead from the "download" icon.
class _PartialCourseButton extends StatelessWidget {
  const _PartialCourseButton({required this.iconSize, required this.onTap});

  final double iconSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final boxSize = iconSize + 8;
    final iconColor =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;

    return IconButton(
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      tooltip: 'Partially downloaded — tap to manage',
      onPressed: onTap,
      icon: SizedBox(
        width: iconSize,
        height: iconSize,
        child: CustomPaint(
          size: Size(iconSize, iconSize),
          painter: _PartialDownloadedPainter(arrowColor: iconColor),
        ),
      ),
    );
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

  // Arrow rendered at ~55 % of the circle diameter so it sits
  // comfortably inside the ring or filled circle.
  double get _innerArrowSize => iconSize * 0.55;

  @override
  Widget build(BuildContext context) {
    final boxSize = iconSize + 8;
    final iconColor =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;
    final borderColor = iconColor;

    switch (state.status) {
      // Progress ring with a centred solid arrow — always tappable to cancel.
      // Determinate when aggregate progress > 0, indeterminate otherwise
      // (Flutter self-animates when value is null).
      case DownloadStatus.pending:
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          tooltip: 'Downloading — tap to cancel',
          onPressed: onDelete,
          icon: SizedBox(
            width: iconSize,
            height: iconSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: state.requestedProgress > 0
                      ? state.requestedProgress
                      : null,
                  strokeWidth: 2,
                  color: iconColor,
                ),
                _DownloadArrow(size: _innerArrowSize, color: iconColor),
              ],
            ),
          ),
        );

      // Filled green circle with a white solid arrow — clearly "done".
      case DownloadStatus.downloaded:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          tooltip: 'Downloaded — tap to remove',
          onPressed: onDelete,
          icon: SizedBox(
            width: iconSize,
            height: iconSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                _DownloadArrow(size: _innerArrowSize, color: Colors.white),
              ],
            ),
          ),
        );

      // Outlined circle with arrow + badge dot for "new version available".
      case DownloadStatus.stale:
        return Stack(
          alignment: Alignment.topRight,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  BoxConstraints(minWidth: boxSize, minHeight: boxSize),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: 'New version available — tap to update',
              onPressed: onDownload,
              icon: SizedBox(
                width: iconSize,
                height: iconSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: iconSize,
                      height: iconSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: borderColor, width: 1.5),
                      ),
                    ),
                    _DownloadArrow(size: _innerArrowSize, color: iconColor),
                  ],
                ),
              ),
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
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(
            Icons.error_outline,
            size: iconSize,
            color: Theme.of(context).colorScheme.error,
          ),
          tooltip: 'Download failed — tap to retry',
          onPressed: onDownload,
        );

      // Plain solid arrow, no circle — same arrow size and centre-point as the
      // downloading state so there is no jump when the progress ring appears.
      case DownloadStatus.notDownloaded:
        return IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          tooltip: 'Download for offline viewing',
          onPressed: onDownload,
          icon: SizedBox(
            width: iconSize,
            height: iconSize,
            child: Center(
              child: _DownloadArrow(size: _innerArrowSize, color: iconColor),
            ),
          ),
        );
    }
  }
}

/// Fat solid download arrow: a thick rectangular stem topped with a wide
/// filled triangle, custom-painted so the arrowhead reads as a solid shape
/// rather than a Material chevron.
class _DownloadArrow extends StatelessWidget {
  const _DownloadArrow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _DownloadArrowPainter(color: color),
    );
  }
}

class _DownloadArrowPainter extends CustomPainter {
  const _DownloadArrowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;

    // Stem: 28 % wide, occupies the top ~46 % of the canvas (with a small
    // top gap so the arrow doesn't clip at the edge inside a circle).
    final stemW = w * 0.28;
    final stemLeft = (w - stemW) / 2;
    canvas.drawRect(
      Rect.fromLTWH(stemLeft, h * 0.06, stemW, h * 0.46),
      paint,
    );

    // Arrowhead: solid triangle, full canvas width at the join, tip at
    // the vertical centre-bottom (with a small bottom gap).
    final path = Path()
      ..moveTo(0, h * 0.48)
      ..lineTo(w, h * 0.48)
      ..lineTo(w / 2, h * 0.94)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DownloadArrowPainter old) => old.color != color;
}

/// Paints the top half of the downloaded disc (green semicircle + white stem)
/// on top, and the bottom half of the download arrow (arrowhead only) below.
class _PartialDownloadedPainter extends CustomPainter {
  const _PartialDownloadedPainter({required this.arrowColor});

  final Color arrowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Top half: green semicircle with the white arrow stem inside.
    final stemW = w * 0.28;
    final stemLeft = (w - stemW) / 2;
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, w, h / 2))
      ..drawCircle(
        Offset(w / 2, h / 2),
        w / 2,
        Paint()..color = Colors.green,
      )
      ..drawRect(
        Rect.fromLTWH(stemLeft, h * 0.06, stemW, h * 0.44),
        Paint()..color = Colors.white,
      )
      ..restore();

    // Bottom half: plain arrowhead in the ambient icon color.
    final path = Path()
      ..moveTo(0, h * 0.5)
      ..lineTo(w, h * 0.5)
      ..lineTo(w / 2, h * 0.94)
      ..close();
    canvas.drawPath(path, Paint()..color = arrowColor);
  }

  @override
  bool shouldRepaint(_PartialDownloadedPainter old) =>
      old.arrowColor != arrowColor;
}
