import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:omnilect/features/courses/providers/ocw_courses_provider.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/downloads/widgets/download_button.dart';
import 'package:omnilect/features/downloads/widgets/download_progress_bar.dart';
import 'package:omnilect/features/progress/providers/course_position_provider.dart';
import 'package:omnilect/features/sync/models/course_sync_state.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
import 'package:url_launcher/url_launcher.dart';

// ignore_for_file: uri_has_not_been_generated

class CourseOutlineScreen extends ConsumerWidget {
  const CourseOutlineScreen({required this.courseId, super.key});

  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (courseId.startsWith('ocw:')) {
      return _OcwCourseOutlineView(courseId: courseId);
    }

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
            onRefresh: () => ref
                .read(syncControllerProvider.notifier)
                .syncCourse(courseId, trigger: kTriggerPullToRefresh),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DownloadProgressBar(
                    courseId: courseId,
                    useLectureCount: true,
                  ),
                ),
                SliverToBoxAdapter(
                  child: _MitxContinueSection(
                    courseId: courseId,
                    outline: outline,
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
    this.onTapOverride,
  });

  final String courseId;
  final String sequenceId;
  final int sectionIndex;
  final int sequenceIndex;
  final String title;

  /// When set, overrides the default onTap — the Continue section uses this
  /// so the tap fires `continue_resume` analytics before navigating.
  final VoidCallback? onTapOverride;

  void _handleTap(BuildContext context, WidgetRef ref, SequenceSyncStatus status) {
    if (onTapOverride != null && status == SequenceSyncStatus.synced) {
      onTapOverride!();
      return;
    }
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
    final trackedLectureId = ref.watch(
      courseWatchPositionProvider(courseId).select((a) => a.asData?.value?.lectureId),
    );
    final isTracked = trackedLectureId == sequenceId;
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
          leading: Icon(
            isTracked ? Icons.play_circle : Icons.play_circle_outline,
            color: iconColor,
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

// ---------------------------------------------------------------------------
// Continue section (MITx)
// ---------------------------------------------------------------------------

/// Top-of-outline "Continue where you left off" entry. Hidden when no
/// `course_positions` row exists for [courseId].
class _MitxContinueSection extends ConsumerWidget {
  const _MitxContinueSection({required this.courseId, required this.outline});

  final String courseId;
  final CourseOutline outline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref
        .watch(courseWatchPositionProvider(courseId))
        .asData
        ?.value;
    if (row == null) return const SizedBox.shrink();

    // Find section + sequence indices for the tracked sequence. If it's not
    // in the outline (structure drifted), don't render — the validator will
    // clear the row on next sync.
    int? sectionIndex;
    int? sequenceIndex;
    for (var s = 0; s < outline.outline.sections.length; s++) {
      final seqs = outline.outline.sections[s].sequenceIds;
      final i = seqs.indexOf(row.lectureId);
      if (i >= 0) {
        sectionIndex = s;
        sequenceIndex = i;
        break;
      }
    }
    if (sectionIndex == null || sequenceIndex == null) {
      return const SizedBox.shrink();
    }

    final title = outline.outline.sequences[row.lectureId]?.title ??
        'Continue lecture';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeaderTile(title: 'Continue'),
        _SequenceTile(
          courseId: courseId,
          sequenceId: row.lectureId,
          sectionIndex: sectionIndex,
          sequenceIndex: sequenceIndex,
          title: title,
          onTapOverride: () {
            ref.read(analyticsServiceProvider).logContinueResume(
                  courseId: courseId,
                  lectureId: row.lectureId,
                  platform: kPlatformMitx,
                  positionSeconds: row.positionSeconds,
                );
            context.push('/course/$courseId/sequence/${row.lectureId}');
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// OCW outline view
// ---------------------------------------------------------------------------

/// Shares the same visual shell as the MITx outline but sources its data from
/// `cached_ocw_courses` / `cached_ocw_lectures` / `cached_ocw_resources`.
/// Only rendered when `courseId` has the `ocw:` prefix.
class _OcwCourseOutlineView extends ConsumerWidget {
  const _OcwCourseOutlineView({required this.courseId});

  final String courseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final courseAsync = ref.watch(ocwCourseProvider(courseId));
    return Scaffold(
      appBar: AppBar(
        title: courseAsync.maybeWhen(
          data: (c) => Text(c?.title ?? 'Course Outline',
              overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Course Outline'),
        ),
        actions: [
          DownloadButton(courseId: courseId),
          const SizedBox(width: 8),
        ],
      ),
      body: courseAsync.when(
        loading: () => const _CourseOutlineSkeleton(),
        error: (_, _) => const _CourseOutlineSkeleton(),
        data: (course) {
          if (course == null) return const _CourseOutlineSkeleton();
          return RefreshIndicator(
            onRefresh: () => ref
                .read(syncControllerProvider.notifier)
                .syncCourse(courseId, trigger: kTriggerPullToRefresh),
            child: _OcwOutlineBody(course: course),
          );
        },
      ),
    );
  }
}

class _OcwOutlineBody extends ConsumerWidget {
  const _OcwOutlineBody({required this.course});

  final CachedOcwCourse course;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(appDatabaseProvider);
    return FutureBuilder<_OcwOutlineData>(
      future: _loadData(db, course.courseId),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) return const _CourseOutlineSkeleton();
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: DownloadProgressBar(
                courseId: course.courseId,
                useLectureCount: true,
              ),
            ),
            if (course.description.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    course.description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: _OcwContinueSection(
                courseId: course.courseId,
                lectures: data.lectures,
              ),
            ),
            SliverToBoxAdapter(
              child: _SectionHeaderTile(
                title: data.lectures.isEmpty
                    ? 'Lectures'
                    : data.lectures.first.sectionTitle,
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final lecture = data.lectures[index];
                  return _OcwLectureTile(
                    courseId: course.courseId,
                    lecture: lecture,
                  );
                },
                childCount: data.lectures.length,
              ),
            ),
            if (data.orphans.isNotEmpty) ...[
              const SliverToBoxAdapter(
                child: _SectionHeaderTile(title: 'Resources'),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _OcwOrphanResourceTile(resource: data.orphans[index]),
                  childCount: data.orphans.length,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<_OcwOutlineData> _loadData(AppDatabase db, String courseId) async {
    final lectures = await db.getOcwLectures(courseId);
    final orphans = await db.getOrphanOcwResources(courseId);
    return _OcwOutlineData(lectures: lectures, orphans: orphans);
  }
}

class _OcwOutlineData {
  const _OcwOutlineData({required this.lectures, required this.orphans});
  final List<CachedOcwLecture> lectures;
  final List<CachedOcwResource> orphans;
}

class _OcwLectureTile extends ConsumerWidget {
  const _OcwLectureTile({
    required this.courseId,
    required this.lecture,
    this.onTapOverride,
  });

  final String courseId;
  final CachedOcwLecture lecture;

  /// When set, overrides the default onTap — the Continue section uses this
  /// so the tap fires `continue_resume` analytics before navigating.
  final VoidCallback? onTapOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final hasVideo = lecture.mp4Url != null;
    final subtitleColor = cs.onSurface.withValues(alpha: 0.6);
    final trackedLectureId = ref.watch(
      courseWatchPositionProvider(courseId)
          .select((a) => a.asData?.value?.lectureId),
    );
    final isTracked = trackedLectureId == lecture.lectureId;
    final leadingIcon = hasVideo
        ? (isTracked ? Icons.play_circle : Icons.play_circle_outline)
        : Icons.videocam_off_outlined;
    return ListTile(
      leading: Icon(leadingIcon, color: cs.onSurfaceVariant),
      title: Text(lecture.title),
      subtitle: hasVideo
          ? null
          : Text(
              'Video not available',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: subtitleColor),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mirror the per-sequence download affordance from the MITx outline.
          // Each OCW lecture maps 1:1 to a video URL, so scope it as a vertical.
          if (hasVideo)
            DownloadButton(courseId: courseId, verticalId: lecture.lectureId),
          Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        ],
      ),
      onTap: () => _tap(context),
    );
  }

  void _tap(BuildContext context) {
    if (onTapOverride != null) {
      onTapOverride!();
      return;
    }
    // Reuses the MITx LectureScreen route — LecturePlayer.build dispatches on
    // the `ocw:` courseId prefix and treats the sequenceId path segment as
    // the OCW lectureSlug. One player, one route, one UX.
    context.push('/course/$courseId/sequence/${lecture.slug}');
  }
}

// ---------------------------------------------------------------------------
// Continue section (OCW)
// ---------------------------------------------------------------------------

class _OcwContinueSection extends ConsumerWidget {
  const _OcwContinueSection({required this.courseId, required this.lectures});

  final String courseId;
  final List<CachedOcwLecture> lectures;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref
        .watch(courseWatchPositionProvider(courseId))
        .asData
        ?.value;
    if (row == null) return const SizedBox.shrink();
    final match = lectures.where((l) => l.lectureId == row.lectureId).toList();
    if (match.isEmpty) return const SizedBox.shrink();
    final lecture = match.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeaderTile(title: 'Continue'),
        _OcwLectureTile(
          courseId: courseId,
          lecture: lecture,
          onTapOverride: () {
            ref.read(analyticsServiceProvider).logContinueResume(
                  courseId: courseId,
                  lectureId: lecture.lectureId,
                  platform: kPlatformOcw,
                  positionSeconds: row.positionSeconds,
                );
            context.push('/course/$courseId/sequence/${lecture.slug}');
          },
        ),
      ],
    );
  }
}

class _OcwOrphanResourceTile extends StatelessWidget {
  const _OcwOrphanResourceTile({required this.resource});

  final CachedOcwResource resource;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.picture_as_pdf_outlined),
      title: Text(resource.title),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => unawaited(launchUrl(
        Uri.parse(resource.url),
        mode: LaunchMode.externalApplication,
      )),
    );
  }
}
