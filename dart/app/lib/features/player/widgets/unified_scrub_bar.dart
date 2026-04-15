import 'package:flutter/material.dart';

/// A horizontal progress/seek bar spanning the full stitched lecture duration.
///
/// Optionally renders thin tick marks at [segmentBoundaries] to indicate where
/// individual video clips start.
///
/// [onSeekStart] / [onSeekEnd] allow the host to pause the
/// auto-position ticker during scrubbing so the thumb doesn't jump.
class UnifiedScrubBar extends StatefulWidget {
  const UnifiedScrubBar({
    required this.position,
    required this.duration,
    required this.onSeek,
    super.key,
    this.segmentBoundaries = const [],
    this.onSeekStart,
    this.onSeekEnd,
  });

  /// Current playback position in seconds.
  final double position;

  /// Total duration of the stitched lecture in seconds.
  final double duration;

  /// Called while the user drags the thumb and on final release.
  final ValueChanged<double> onSeek;

  /// Optional: global-time offsets (seconds) at which segment dividers are drawn.
  final List<double> segmentBoundaries;

  /// Called when the user first touches the bar.
  final VoidCallback? onSeekStart;

  /// Called when the user releases the bar.
  final VoidCallback? onSeekEnd;

  @override
  State<UnifiedScrubBar> createState() => _UnifiedScrubBarState();
}

class _UnifiedScrubBarState extends State<UnifiedScrubBar> {
  double? _dragPosition;
  bool _dragging = false;

  double get _displayPosition => _dragging ? (_dragPosition ?? widget.position) : widget.position;

  double _clampedFrac(double pos) {
    if (widget.duration <= 0) return 0;
    return (pos / widget.duration).clamp(0.0, 1.0);
  }

  void _handleTapOrDrag(Offset localPos, double width) {
    if (widget.duration <= 0) return;
    final frac = (localPos.dx / width).clamp(0.0, 1.0);
    final secs = frac * widget.duration;
    setState(() => _dragPosition = secs);
  }

  void _commitSeek() {
    if (widget.duration <= 0) return;
    widget.onSeek(_dragPosition ?? widget.position);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    // Suppress the iOS swipe-back gesture while the user is dragging the
    // scrub handle — a horizontal drag near the left edge would otherwise
    // accidentally navigate away.
    return PopScope(
      canPop: !_dragging,
      child: SizedBox(
        height: 36,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) {
                setState(() {
                  _dragging = true;
                  _dragPosition = _clampedFrac(d.localPosition.dx / width) * widget.duration;
                });
                widget.onSeekStart?.call();
              },
              onHorizontalDragUpdate: (d) {
                _handleTapOrDrag(d.localPosition, width);
              },
              onHorizontalDragEnd: (_) {
                _commitSeek();
                widget.onSeekEnd?.call();
                setState(() => _dragging = false);
              },
              onTapDown: (d) {
                widget.onSeekStart?.call();
                _handleTapOrDrag(d.localPosition, width);
                _commitSeek();
                widget.onSeekEnd?.call();
              },
              child: CustomPaint(
                size: Size(width, 36),
                painter: _ScrubBarPainter(
                  position: _displayPosition,
                  duration: widget.duration,
                  segmentBoundaries: widget.segmentBoundaries,
                  progressColor: primaryColor,
                  trackColor: theme.colorScheme.surfaceContainerHighest,
                  thumbColor: primaryColor,
                  dividerColor: Colors.white.withValues(alpha: 0.6),
                  isDragging: _dragging,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScrubBarPainter extends CustomPainter {
  _ScrubBarPainter({
    required this.position,
    required this.duration,
    required this.segmentBoundaries,
    required this.progressColor,
    required this.trackColor,
    required this.thumbColor,
    required this.dividerColor,
    required this.isDragging,
  });

  final double position;
  final double duration;
  final List<double> segmentBoundaries;
  final Color progressColor;
  final Color trackColor;
  final Color thumbColor;
  final Color dividerColor;
  final bool isDragging;

  @override
  void paint(Canvas canvas, Size size) {
    const trackHeight = 4.0;
    const thumbRadius = 7.0;
    const trackY = 18.0; // vertically centred in the 36-height box

    final frac = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final progressWidth = frac * size.width;

    final trackPaint = Paint()
      ..color = trackColor
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = progressColor
      ..strokeCap = StrokeCap.round;

    // Background track.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, trackY - trackHeight / 2, size.width, trackHeight),
        const Radius.circular(2),
      ),
      trackPaint,
    );

    // Progress portion.
    if (progressWidth > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, trackY - trackHeight / 2, progressWidth, trackHeight),
          const Radius.circular(2),
        ),
        progressPaint,
      );
    }

    // Segment boundary dividers.
    if (duration > 0) {
      final divPaint = Paint()
        ..color = dividerColor
        ..strokeWidth = 1.5;
      for (final boundary in segmentBoundaries) {
        if (boundary <= 0 || boundary >= duration) continue;
        final x = (boundary / duration) * size.width;
        canvas.drawLine(
          Offset(x, trackY - 6),
          Offset(x, trackY + 6),
          divPaint,
        );
      }
    }

    // Thumb.
    final thumbX = progressWidth.clamp(thumbRadius, size.width - thumbRadius);
    final thumbPaint = Paint()..color = thumbColor;
    canvas.drawCircle(
      Offset(thumbX, trackY),
      isDragging ? thumbRadius + 2 : thumbRadius,
      thumbPaint,
    );
  }

  @override
  bool shouldRepaint(_ScrubBarPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.duration != duration ||
      oldDelegate.isDragging != isDragging;
}
