import 'package:emajtee/features/courses/widgets/html_block.dart';
import 'package:emajtee/features/player/models/vertical_segment.dart';
import 'package:flutter/material.dart';

/// A collapsible row in the lecture content list representing one vertical.
///
/// The header is always visible and shows the section title, optional video
/// duration, and an optional play button. Tapping the header expands/collapses
/// the section. Tapping the play button starts playback from this section's
/// position (without toggling expansion).
class VerticalSectionTile extends StatelessWidget {
  const VerticalSectionTile({
    required this.segment,
    required this.isExpanded,
    required this.onTap,
    super.key,
    this.onPlay,
  });

  final VerticalSegment segment;
  final bool isExpanded;

  /// Called when the user taps the header row to toggle expansion.
  final VoidCallback onTap;

  /// Called when the user taps the play button. Null if this segment has no
  /// video (play button is hidden).
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row.
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Expand/collapse icon.
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),

                // Title.
                Expanded(
                  child: Text(
                    segment.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isExpanded ? FontWeight.w600 : FontWeight.normal,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Duration label (if has video).
                if (segment.videoUrl != null && segment.videoDuration > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    _formatDuration(segment.videoDuration),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],

                // Play button (if has video).
                if (onPlay != null) ...[
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.play_circle_outline, size: 26),
                      color: theme.colorScheme.primary,
                      tooltip: 'Play from here',
                      onPressed: onPlay,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Expanded content.
        if (isExpanded) _ExpandedContent(segment: segment),

        const Divider(height: 1),
      ],
    );
  }

  static String _formatDuration(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------

class _ExpandedContent extends StatelessWidget {
  const _ExpandedContent({required this.segment});

  final VerticalSegment segment;

  @override
  Widget build(BuildContext context) {
    final html = segment.safeHtmlContent.trim();

    if (html.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(44, 0, 16, 12),
        child: Text(
          'No additional content for this section.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: HtmlBlock(html: html),
    );
  }
}
