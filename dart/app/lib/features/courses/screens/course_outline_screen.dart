import 'package:emajtee/features/courses/models/outline.dart';
import 'package:emajtee/features/courses/providers/outline_provider.dart';
import 'package:emajtee/features/downloads/widgets/download_button.dart';
import 'package:emajtee/features/downloads/widgets/download_progress_bar.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:emajtee/features/sync/providers/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CourseOutlineScreen extends ConsumerStatefulWidget {
  const CourseOutlineScreen({required this.courseId, super.key});

  final String courseId;

  @override
  ConsumerState<CourseOutlineScreen> createState() =>
      _CourseOutlineScreenState();
}

class _CourseOutlineScreenState extends ConsumerState<CourseOutlineScreen> {
  // Section indexes that are currently expanded. First section starts open.
  final Set<int> _expandedSectionIndexes = {0};

  void _toggleSection(int index) {
    setState(() {
      if (_expandedSectionIndexes.contains(index)) {
        _expandedSectionIndexes.remove(index);
      } else {
        _expandedSectionIndexes.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final outlineAsync =
        ref.watch(courseOutlineProvider(courseId: widget.courseId));

    return Scaffold(
      appBar: AppBar(
        title: outlineAsync.maybeWhen(
          data: (o) => Text(
            o.title,
            overflow: TextOverflow.ellipsis,
          ),
          orElse: () => const Text('Course Outline'),
        ),
        actions: [
          // Per-course refresh button.
          Builder(builder: (context) {
            final syncStatus = ref.watch(syncControllerProvider
                .select((s) => s[widget.courseId]?.status ?? SyncStatus.idle));
            final isSyncing = syncStatus == SyncStatus.syncing;
            final hasError = syncStatus == SyncStatus.error;
            if (isSyncing) {
              return const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            return IconButton(
              icon: Icon(
                Icons.sync,
                color: hasError ? Theme.of(context).colorScheme.error : null,
              ),
              tooltip: 'Refresh course',
              onPressed: () => ref
                  .read(syncControllerProvider.notifier)
                  .syncCourse(widget.courseId),
            );
          }),
          // Course-level download button.
          DownloadButton(courseId: widget.courseId),
          const SizedBox(width: 8),
        ],
      ),
      body: outlineAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text('Could not load course outline'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(
                    courseOutlineProvider(courseId: widget.courseId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (outline) {
          final sections = outline.outline.sections;
          return RefreshIndicator(
            onRefresh: () async => ref
                .invalidate(courseOutlineProvider(courseId: widget.courseId)),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DownloadProgressBar(courseId: widget.courseId),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      return _SectionGroup(
                        section: sections[index],
                        sectionIndex: index,
                        isExpanded: _expandedSectionIndexes.contains(index),
                        onToggle: () => _toggleSection(index),
                        courseId: widget.courseId,
                        outline: outline,
                      );
                    },
                    childCount: sections.length,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Renders a collapsible section header followed by its sequence tiles.
class _SectionGroup extends StatelessWidget {
  const _SectionGroup({
    required this.section,
    required this.sectionIndex,
    required this.isExpanded,
    required this.onToggle,
    required this.courseId,
    required this.outline,
  });

  final Section section;
  final int sectionIndex;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String courseId;
  final CourseOutline outline;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeaderTile(
          title: section.title,
          isExpanded: isExpanded,
          onTap: onToggle,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: isExpanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < section.sequenceIds.length; i++)
                      _SequenceTile(
                        courseId: courseId,
                        sequenceId: section.sequenceIds[i],
                        title: outline.outline.sequences[section.sequenceIds[i]]
                                ?.title ??
                            'Part ${i + 1}',
                        onTap: () => context.push(
                          '/course/$courseId/sequence/${section.sequenceIds[i]}',
                        ),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _SectionHeaderTile extends StatelessWidget {
  const _SectionHeaderTile({
    required this.title,
    required this.isExpanded,
    required this.onTap,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            AnimatedRotation(
              turns: isExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _SequenceTile extends StatelessWidget {
  const _SequenceTile({
    required this.courseId,
    required this.sequenceId,
    required this.title,
    required this.onTap,
  });

  final String courseId;
  final String sequenceId;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.play_circle_outline),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DownloadButton(courseId: courseId, sequenceId: sequenceId),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}
