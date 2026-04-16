import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/downloads/widgets/download_button.dart';
import 'package:omnilect/features/downloads/widgets/download_progress_bar.dart';
import 'package:omnilect/features/sync/models/course_sync_state.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
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
        loading: () => const _CourseOutlineSkeleton(),
        error: (_, _) => const _CourseOutlineSkeleton(),
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
// Skeleton loading state — shown while outline data is not yet cached.
// ---------------------------------------------------------------------------

class _CourseOutlineSkeleton extends StatefulWidget {
  const _CourseOutlineSkeleton();

  @override
  State<_CourseOutlineSkeleton> createState() => _CourseOutlineSkeletonState();
}

class _CourseOutlineSkeletonState extends State<_CourseOutlineSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  // Fake section/sequence counts that look like a real course.
  static const _sections = [3, 4, 2, 3];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final shimmer = Color.lerp(
          cs.surfaceContainerHighest,
          cs.surfaceContainerLowest,
          _pulse.value,
        )!;
        final shimmerDim = Color.lerp(
          cs.surfaceContainerHighest,
          cs.surfaceContainer,
          _pulse.value,
        )!;

        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var s = 0; s < _sections.length; s++) ...[
              // Section header placeholder.
              Container(
                color: cs.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: _SkeletonBox(
                  color: shimmerDim,
                  width: _titleWidth(s, 0),
                  height: 14,
                ),
              ),
              // Sequence tile placeholders.
              for (var i = 0; i < _sections[s]; i++)
                _SkeletonTile(
                  shimmer: shimmer,
                  titleWidth: _titleWidth(s, i + 1),
                ),
            ],
          ],
        );
      },
    );
  }

  // Vary widths so the skeleton looks natural rather than uniform.
  static const _widthTable = [0.72, 0.58, 0.81, 0.65, 0.76, 0.53, 0.69, 0.84];
  double _titleWidth(int s, int i) =>
      _widthTable[(s * 3 + i) % _widthTable.length];
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({required this.shimmer, required this.titleWidth});

  final Color shimmer;
  final double titleWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          // Leading icon placeholder.
          _SkeletonBox(
            color: shimmer,
            width: 40,
            height: 40,
            radius: 20,
          ),
          const SizedBox(width: 16),
          // Title placeholder.
          Expanded(
            child: _SkeletonBox(
              color: shimmer,
              widthFactor: titleWidth,
              height: 14,
            ),
          ),
          const SizedBox(width: 12),
          // Trailing chevron placeholder.
          _SkeletonBox(
            color: cs.surfaceContainerHighest,
            width: 20,
            height: 20,
            radius: 4,
          ),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.color,
    required this.height,
    this.width,
    this.widthFactor,
    this.radius = 6,
  }) : assert(
          width != null || widthFactor != null,
          'Provide width or widthFactor',
        );

  final Color color;
  final double? width;
  final double? widthFactor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    Widget box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    if (widthFactor != null) {
      box = FractionallySizedBox(widthFactor: widthFactor, child: box);
    }
    return box;
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

    final isSynced = status == SequenceSyncStatus.synced;
    final isSyncing = status == SequenceSyncStatus.syncing;
    final isError = status == SequenceSyncStatus.error;

    final progress = (seqState == null || seqState.totalTasks == 0)
        ? 0.0
        : (seqState.completedTasks / seqState.totalTasks).clamp(0.0, 1.0);

    // Gray out text + leading/trailing icons for any row that isn't fully
    // synced yet. Uses Material 3's standard disabled opacity (0.38) so the
    // "not ready to open" state reads clearly as disabled, not just as
    // secondary text.
    final disabledFg = cs.onSurface.withValues(alpha: 0.38);
    final titleColor = isSynced ? null : disabledFg;
    final iconColor = isSynced ? null : disabledFg;

    return Stack(
      children: [
        // Full-row background progress fill — only while actively syncing.
        if (isSyncing)
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              builder: (_, v, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: v,
                child: ColoredBox(
                  color: cs.primaryContainer.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ListTile(
          leading: IconButton(
            icon: const Icon(Icons.play_circle_outline),
            color: iconColor,
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
          title: Text(title, style: TextStyle(color: titleColor)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isError) ...[
                Icon(Icons.error_outline, color: cs.error, size: 18),
                const SizedBox(width: 4),
              ],
              // Download button hidden until the sequence is fully synced — no
              // point offering video download before we know what videos exist.
              if (isSynced)
                DownloadButton(courseId: courseId, sequenceId: sequenceId),
              Icon(Icons.chevron_right, color: iconColor),
            ],
          ),
          onTap: () => _handleTap(context, ref, status),
        ),
      ],
    );
  }
}
