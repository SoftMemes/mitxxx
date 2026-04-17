import 'package:flutter/material.dart';
import 'package:omnilect/features/courses/widgets/html_block.dart';
import 'package:omnilect/features/player/models/vertical_segment.dart';

/// A collapsible row in the lecture content list representing one vertical.
///
/// The header is always visible and shows the section title and optional
/// video duration. Tapping the header seeks the video to this section's
/// start and expands the tile. Play/pause state is preserved across the
/// seek (driven by the caller via [onTap]).
class VerticalSectionTile extends StatelessWidget {
  const VerticalSectionTile({
    required this.segment,
    required this.isExpanded,
    required this.onTap,
    super.key,
  });

  final VerticalSegment segment;
  final bool isExpanded;

  /// Called when the user taps the header row.
  final VoidCallback onTap;

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
