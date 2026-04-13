import 'package:emajtee/features/courses/models/outline.dart';
import 'package:emajtee/features/courses/providers/outline_provider.dart';
import 'package:emajtee/features/downloads/widgets/download_button.dart';
import 'package:emajtee/features/downloads/widgets/download_progress_bar.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:emajtee/features/sync/providers/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class CourseOutlineScreen extends ConsumerWidget {
  const CourseOutlineScreen({super.key, required this.courseId});

  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outlineAsync =
        ref.watch(courseOutlineProvider(courseId: courseId));

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
            final syncStatus = ref
                .watch(syncControllerProvider
                    .select((s) => s[courseId]?.status ?? SyncStatus.idle));
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
                color: hasError
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              tooltip: 'Refresh course',
              onPressed: () => ref
                  .read(syncControllerProvider.notifier)
                  .syncCourse(courseId),
            );
          }),
          // Course-level download button.
          DownloadButton(courseId: courseId),
          const SizedBox(width: 8),
        ],
      ),
      body: outlineAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('Could not load course outline'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(courseOutlineProvider(courseId: courseId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (outline) {
          final items = _buildItems(outline.outline.sections, outline);

          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(courseOutlineProvider(courseId: courseId)),
            child: CustomScrollView(
              slivers: [
                // Course-level progress bar (shown below AppBar when partially
                // or fully downloaded).
                SliverToBoxAdapter(
                  child: DownloadProgressBar(courseId: courseId),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final item = items[index];
                      if (item is _SectionHeader) {
                        return _SectionHeaderTile(title: item.title);
                      } else if (item is _SequenceEntry) {
                        return _SequenceTile(
                          courseId: courseId,
                          sequenceId: item.sequenceId,
                          title: item.title,
                          onTap: () => context.push(
                            '/course/$courseId/sequence/${item.sequenceId}',
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                    childCount: items.length,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Object> _buildItems(List<Section> sections, CourseOutline outline) {
    final items = <Object>[];
    for (final section in sections) {
      items.add(_SectionHeader(title: section.title));
      for (var i = 0; i < section.sequenceIds.length; i++) {
        final seqId = section.sequenceIds[i];
        final seqTitle = outline.outline.sequences[seqId]?.title;
        items.add(
          _SequenceEntry(
            sequenceId: seqId,
            title: seqTitle ?? 'Part ${i + 1}',
          ),
        );
      }
    }
    return items;
  }
}

class _SectionHeader {
  const _SectionHeader({required this.title});
  final String title;
}

class _SequenceEntry {
  const _SequenceEntry({required this.sequenceId, required this.title});
  final String sequenceId;
  final String title;
}

class _SectionHeaderTile extends StatelessWidget {
  const _SectionHeaderTile({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

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
