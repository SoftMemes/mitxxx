import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/courses/providers/course_image_provider.dart';
import 'package:omnilect/features/courses/providers/enrollments_provider.dart';
import 'package:omnilect/features/courses/providers/ocw_courses_provider.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/courses/providers/unsupported_courses_provider.dart';
import 'package:omnilect/features/sync/models/course_sync_state.dart';
import 'package:omnilect/features/sync/providers/sync_controller.dart';
import 'package:url_launcher/url_launcher.dart';

/// MIT Learn dashboard for managing course enrollments.
const _kManageCoursesUrl = 'https://learn.mit.edu/dashboard';

Future<void> _openManageCourses() => launchUrl(
      Uri.parse(_kManageCoursesUrl),
      mode: LaunchMode.externalApplication,
    );

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _autoSyncTriggered = false;

  @override
  Widget build(BuildContext context) {
    final enrollmentsAsync = ref.watch(activeEnrollmentsProvider);
    final syncState = ref.watch(syncControllerProvider);
    final isSyncing = syncState.values.any((s) => s.status == SyncStatus.syncing);
    final isAuthenticated = ref.watch(authProvider).value != null;

    // Auto-trigger an initial sync when logged in and there is no cached data
    // yet (e.g. first login). Only do this once per screen lifecycle.
    if (isAuthenticated &&
        !_autoSyncTriggered &&
        enrollmentsAsync.hasError &&
        !isSyncing) {
      _autoSyncTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(syncControllerProvider.notifier).syncAll(trigger: kTriggerAuto);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Courses'),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => context.push('/settings'),
          ),
        ],
        bottom: isSyncing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: !isAuthenticated
          ? _LoggedOutState(onLogin: () => context.go('/login'))
          : enrollmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _PullToSyncWrapper(
          onRefresh: () async {
            final controller =
                ref.read(syncControllerProvider.notifier);
            await controller.stopAll();
            await controller.syncAll(
              trigger: kTriggerPullToRefresh,
            );
          },
          child: _EmptyState(
            isSyncing: isSyncing,
            onSync: () =>
                ref.read(syncControllerProvider.notifier).syncAll(),
          ),
        ),
        data: (enrollments) {
          Future<void> restartSync() async {
            final controller = ref.read(syncControllerProvider.notifier);
            await controller.stopAll();
            await controller.syncAll(trigger: kTriggerPullToRefresh);
          }

          final unsupported =
              ref.watch(unsupportedCoursesProvider).asData?.value ??
                  const <UnsupportedCourse>[];
          final ocwCourses =
              ref.watch(activeOcwCoursesProvider).asData?.value ??
                  const <CachedOcwCourse>[];

          if (enrollments.isEmpty && ocwCourses.isEmpty && unsupported.isEmpty) {
            return _PullToSyncWrapper(
              onRefresh: restartSync,
              child: const _NotEnrolledState(),
            );
          }

          final totalCount = enrollments.length +
              ocwCourses.length +
              (unsupported.isNotEmpty ? unsupported.length + 1 : 0);

          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: restartSync,
                  child: ListView.separated(
                    itemCount: totalCount,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index < enrollments.length) {
                        final enrollment = enrollments[index];
                        final courseId = enrollment.run.coursewareId;
                        final courseSyncState = syncState[courseId];
                        return _CourseTile(
                          enrollment: enrollment,
                          syncState: courseSyncState,
                          onTap: () {
                            ref.read(analyticsServiceProvider).logCourseView(
                                  courseId: courseId,
                                  source: kSourceCourseList,
                                );
                            context.push('/course/$courseId');
                          },
                        );
                      }
                      final afterEnrolled = index - enrollments.length;
                      if (afterEnrolled < ocwCourses.length) {
                        final course = ocwCourses[afterEnrolled];
                        final courseSyncState = syncState[course.courseId];
                        return _OcwCourseTile(
                          course: course,
                          syncState: courseSyncState,
                          onTap: () {
                            ref.read(analyticsServiceProvider).logCourseView(
                                  courseId: course.courseId,
                                  source: kSourceCourseList,
                                );
                            context.push('/course/${course.courseId}');
                          },
                        );
                      }
                      final unsupportedIndex = afterEnrolled - ocwCourses.length;
                      if (unsupportedIndex == 0) {
                        return const _SectionHeader('Not yet supported');
                      }
                      final course = unsupported[unsupportedIndex - 1];
                      return _UnsupportedCourseTile(course: course);
                    },
                  ),
                ),
              ),
              const Divider(height: 1),
              const SafeArea(
                top: false,
                child: Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: _ManageCoursesLink(
                    prefix: "Can't see your course? Manage courses on",
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoggedOutState extends StatelessWidget {
  const _LoggedOutState({required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_download_outlined, size: 64, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'Log in to sync your enrolled MIT Learn courses for offline access.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onLogin,
              icon: const Icon(Icons.login),
              label: const Text('Log in to sync'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onSync,
    required this.isSyncing,
  });

  final VoidCallback onSync;
  final bool isSyncing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.school_outlined, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'Sync to load your courses.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: isSyncing ? null : onSync,
            icon: isSyncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(isSyncing ? 'Syncing…' : 'Sync now'),
          ),
        ],
      ),
    );
  }
}

/// Makes a non-scrolling empty-state widget support pull-to-refresh by
/// hosting it inside a scrollable that always accepts overscroll. Sized to
/// fill the viewport so the content stays vertically centred.
class _PullToSyncWrapper extends StatelessWidget {
  const _PullToSyncWrapper({
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Shown when the enrollments list has been synced successfully but the user
/// isn't enrolled in any courses. Offers a link to MIT Learn to manage
/// enrollments.
class _NotEnrolledState extends StatelessWidget {
  const _NotEnrolledState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.school_outlined, size: 64, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            const _ManageCoursesLink(
              prefix: 'Not enrolled in any courses, manage your courses on',
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline text ending with a "MIT learn" link that opens the system browser
/// to the MIT Learn course-management dashboard.
class _ManageCoursesLink extends StatefulWidget {
  const _ManageCoursesLink({required this.prefix});

  final String prefix;

  @override
  State<_ManageCoursesLink> createState() => _ManageCoursesLinkState();
}

class _ManageCoursesLinkState extends State<_ManageCoursesLink> {
  late final TapGestureRecognizer _recognizer =
      TapGestureRecognizer()..onTap = _openManageCourses;

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '${widget.prefix} '),
          TextSpan(
            text: 'MIT learn',
            style: TextStyle(
              color: cs.primary,
              decoration: TextDecoration.underline,
            ),
            recognizer: _recognizer,
          ),
        ],
      ),
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _UnsupportedCourseTile extends StatelessWidget {
  const _UnsupportedCourseTile({required this.course});

  final UnsupportedCourse course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final disabled = cs.onSurface.withValues(alpha: 0.38);
    return ListTile(
      enabled: false,
      leading: Icon(Icons.library_books_outlined, color: disabled),
      title: Text(
        course.title,
        style: theme.textTheme.titleMedium?.copyWith(color: disabled),
      ),
      subtitle: Text(
        'Not yet supported · ${course.platformLabel}',
        style: theme.textTheme.bodySmall?.copyWith(color: disabled),
      ),
    );
  }
}

class _CourseTile extends ConsumerWidget {
  const _CourseTile({
    required this.enrollment,
    required this.syncState,
    required this.onTap,
  });

  final Enrollment enrollment;
  final CourseSyncState? syncState;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = enrollment.run;
    final courseId = run.coursewareId;
    final status = syncState?.status ?? SyncStatus.idle;
    final isSyncing = status == SyncStatus.syncing;
    final hasError = status == SyncStatus.error;
    final lastSynced = syncState?.lastSyncedAt;
    final cs = Theme.of(context).colorScheme;

    // "Ready" means the outline itself has been cached, so tapping the tile
    // opens a meaningful course overview — even if individual verticals are
    // still syncing. Per-sequence readiness is shown inside the outline
    // screen by each sequence tile's own disabled state. The course tile
    // only goes gray during the initial outline-fetch window.
    final outlineAsync =
        ref.watch(courseOutlineProvider(courseId: courseId));
    final isReady = outlineAsync.hasValue;

    // Material 3 standard disabled opacity. Used for title/subtitle/chevron
    // while the outline isn't cached yet so the "not ready to open" state
    // reads clearly as disabled rather than as secondary text.
    final disabledFg = cs.onSurface.withValues(alpha: 0.38);

    // Aggregate per-sequence sync state into a course-level progress fraction.
    final progress =
        isSyncing ? _computeCourseProgress(ref, courseId) : 0.0;

    String? dateRange;
    if (run.startDate != null || run.endDate != null) {
      final start = _formatDate(run.startDate);
      final end = _formatDate(run.endDate);
      if (start != null && end != null) {
        dateRange = '$start – $end';
      } else if (start != null) {
        dateRange = 'From $start';
      } else if (end != null) {
        dateRange = 'Until $end';
      }
    }

    final syncLabel = isSyncing
        ? 'Syncing…'
        : hasError
            ? 'Sync failed'
            : lastSynced != null
                ? 'Synced ${_relativeTime(lastSynced)}'
                : 'Not synced';

    final imageUrl = run.course?.featureImageSrc;

    return Stack(
      children: [
        // Full-row background progress fill — only while actively syncing.
        // Matches _SequenceTile in course_outline_screen.dart.
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
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                // Course artwork.
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _CourseArtwork(networkUrl: imageUrl),
                ),
                const SizedBox(width: 12),

                // Course info.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        run.title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: isReady ? null : disabledFg,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        run.courseNumber,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isReady
                                  ? cs.onSurface.withValues(alpha: 0.6)
                                  : disabledFg,
                            ),
                      ),
                      if (dateRange != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          dateRange,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: isReady
                                    ? cs.onSurface.withValues(alpha: 0.5)
                                    : disabledFg,
                              ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (hasError)
                            Icon(Icons.error_outline,
                                size: 14, color: cs.error)
                          else
                            Icon(Icons.check_circle_outline,
                                size: 14,
                                color: lastSynced != null
                                    ? Colors.green
                                    : cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(
                            syncLabel,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: hasError
                                          ? cs.error
                                          : cs.onSurfaceVariant,
                                    ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                Icon(
                  Icons.chevron_right,
                  color: isReady ? cs.onSurfaceVariant : disabledFg,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Aggregates per-sequence sync state into a 0..1 course-level progress
  /// fraction. Returns 0 when the outline isn't cached yet (sync has just
  /// started and the sequence list is unknown).
  double _computeCourseProgress(WidgetRef ref, String courseId) {
    final outline = ref
        .watch(courseOutlineProvider(courseId: courseId))
        .maybeWhen(data: (o) => o, orElse: () => null);
    if (outline == null) return 0;

    final sequenceIds = <String>[
      for (final section in outline.outline.sections) ...section.sequenceIds,
    ];
    if (sequenceIds.isEmpty) return 0;

    final seqStates = ref.watch(sequenceSyncControllerProvider);

    var sum = 0.0;
    for (final seqId in sequenceIds) {
      final s = seqStates[seqId];
      if (s == null) continue;
      switch (s.status) {
        case SequenceSyncStatus.synced:
          sum += 1;
        case SequenceSyncStatus.syncing:
          if (s.totalTasks > 0) {
            sum += (s.completedTasks / s.totalTasks).clamp(0.0, 1.0);
          }
        case SequenceSyncStatus.idle:
        case SequenceSyncStatus.error:
          break;
      }
    }
    return (sum / sequenceIds.length).clamp(0.0, 1.0);
  }

  String? _formatDate(String? dateStr) {
    if (dateStr == null) return null;
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } on Object catch (_) {
      return null;
    }
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Course-tile artwork with an offline-first load path.
///
/// Resolution order:
/// 1. Local file in `CourseImages` (downloaded + rescaled at sync time) —
///    instant, low-memory decode via `cacheWidth: 144`.
/// 2. `networkUrl` — fallback for the first render after a fresh sync,
///    while the downloader is still running.
/// 3. [_ArtworkPlaceholder] — when neither is available.
class _CourseArtwork extends ConsumerWidget {
  const _CourseArtwork({this.networkUrl});

  final String? networkUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = networkUrl;
    if (url == null || url.isEmpty) {
      return _ArtworkPlaceholder();
    }
    final localPathAsync = ref.watch(courseImageLocalPathProvider(url));
    final localPath = localPathAsync.value;
    if (localPath != null && File(localPath).existsSync()) {
      return Image.file(
        File(localPath),
        width: 72,
        height: 72,
        fit: BoxFit.cover,
        cacheWidth: 144,
        errorBuilder: (_, _, _) => _ArtworkPlaceholder(),
      );
    }
    return Image.network(
      url,
      width: 72,
      height: 72,
      fit: BoxFit.cover,
      cacheWidth: 144,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : _ArtworkPlaceholder(),
      errorBuilder: (_, _, _) => _ArtworkPlaceholder(),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.school_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// Visually identical to [_CourseTile] but sources its title + course number
/// from `cached_ocw_courses` rather than MITx enrollments. OCW courses don't
/// have a MIT-Learn artwork URL, dates, or a separate "is ready" signal —
/// presence of the row IS readiness.
class _OcwCourseTile extends ConsumerWidget {
  const _OcwCourseTile({
    required this.course,
    required this.syncState,
    required this.onTap,
  });

  final CachedOcwCourse course;
  final CourseSyncState? syncState;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = syncState?.status ?? SyncStatus.idle;
    final isSyncing = status == SyncStatus.syncing;
    final hasError = status == SyncStatus.error;
    final lastSynced = syncState?.lastSyncedAt;
    final cs = Theme.of(context).colorScheme;

    final syncLabel = isSyncing
        ? 'Syncing…'
        : hasError
            ? 'Sync failed'
            : lastSynced != null
                ? 'Synced ${_relativeLabel(lastSynced)}'
                : 'Not synced';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _CourseArtwork(networkUrl: course.imageUrl),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    course.title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    course.courseNumber,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (hasError)
                        Icon(Icons.error_outline, size: 14, color: cs.error)
                      else
                        Icon(Icons.check_circle_outline,
                            size: 14,
                            color: lastSynced != null
                                ? Colors.green
                                : cs.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        syncLabel,
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: hasError
                                      ? cs.error
                                      : cs.onSurfaceVariant,
                                ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

String _relativeLabel(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
