import 'package:emajtee/core/analytics/analytics_service.dart';
import 'package:emajtee/features/courses/models/outline.dart';
import 'package:emajtee/features/courses/providers/outline_provider.dart';
import 'package:emajtee/features/downloads/widgets/download_button.dart';
import 'package:emajtee/features/downloads/widgets/download_progress_bar.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:emajtee/features/sync/providers/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

// ignore_for_file: uri_has_not_been_generated

class CourseOutlineScreen extends ConsumerWidget {
  const CourseOutlineScreen({required this.courseId, super.key});

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
            final syncStatus = ref.watch(syncControllerProvider
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
                color: hasError ? Theme.of(context).colorScheme.error : null,
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
              Icon(Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text('Could not load course outline'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(
                    courseOutlineProvider(courseId: courseId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (outline) {
          final sections = outline.outline.sections;
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(courseOutlineProvider(courseId: courseId)),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DownloadProgressBar(
                    courseId: courseId,
                    useLectureCount: true,
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      return _SectionGroup(
                        section: sections[index],
                        sectionIndex: index,
                        courseId: courseId,
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

/// Renders a section header followed by all its sequence tiles.
class _SectionGroup extends StatelessWidget {
  const _SectionGroup({
    required this.section,
    required this.sectionIndex,
    required this.courseId,
    required this.outline,
  });

  final Section section;
  final int sectionIndex;
  final String courseId;
  final CourseOutline outline;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeaderTile(title: section.title),
        for (var i = 0; i < section.sequenceIds.length; i++)
          _SequenceTile(
            courseId: courseId,
            sequenceId: section.sequenceIds[i],
            sectionIndex: sectionIndex,
            sequenceIndex: i,
            title: outline.outline.sequences[section.sequenceIds[i]]?.title ??
                'Part ${i + 1}',
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------

class _SequenceTile extends ConsumerWidget {
  const _SequenceTile({
    required this.courseId,
    required this.sequenceId,
    required this.sectionIndex,
    required this.sequenceIndex,
    required this.title,
  });

  final String courseId;
  final String sequenceId;
  final int sectionIndex;
  final int sequenceIndex;
  final String title;

  void _handleTap(BuildContext context, WidgetRef ref, SequenceSyncStatus status) {
    if (status == SequenceSyncStatus.synced) {
      ref.read(analyticsServiceProvider).logSectionOpen(
        courseId: courseId,
        blockId: sequenceId,
        sectionIndex: sectionIndex * 100 + sequenceIndex,
      );
      context.push('/course/$courseId/sequence/$sequenceId');
    } else {
      ref.read(syncControllerProvider.notifier).prioritiseSequence(courseId, sequenceId);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Queued — will sync next'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seqState = ref.watch(
      sequenceSyncControllerProvider.select((m) => m[sequenceId]),
    );
    final status = seqState?.status ?? SequenceSyncStatus.idle;
    final cs = Theme.of(context).colorScheme;

    // Status indicator: only shown while sync hasn't completed. Once the
    // sequence is synced we drop the icon entirely — the absence of an icon
    // is the "synced" signal (and the download button becomes visible).
    Widget? statusIcon;
    switch (status) {
      case SequenceSyncStatus.syncing:
        statusIcon = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case SequenceSyncStatus.error:
        statusIcon = Icon(Icons.error_outline, color: cs.error, size: 18);
      case SequenceSyncStatus.idle:
        statusIcon = Icon(Icons.hourglass_empty, color: cs.onSurfaceVariant, size: 18);
      case SequenceSyncStatus.synced:
        statusIcon = null;
    }

    final isSynced = status == SequenceSyncStatus.synced;

    return ListTile(
      leading: IconButton(
        icon: const Icon(Icons.play_circle_outline),
        tooltip: 'Play from beginning',
        onPressed: () {
          if (isSynced) {
            ref.read(analyticsServiceProvider).logSectionPlay(
              courseId: courseId,
              blockId: sequenceId,
            );
          }
          _handleTap(context, ref, status);
        },
      ),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statusIcon != null) ...[
            statusIcon,
            const SizedBox(width: 4),
          ],
          // Download button hidden until the sequence is fully synced — no
          // point offering video download before we know what videos exist.
          if (isSynced)
            DownloadButton(courseId: courseId, sequenceId: sequenceId),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: () => _handleTap(context, ref, status),
    );
  }
}
