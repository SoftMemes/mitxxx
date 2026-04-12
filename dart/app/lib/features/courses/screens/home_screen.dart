import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:emajtee/features/courses/providers/enrollments_provider.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:emajtee/features/sync/providers/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _autoSyncTriggered = false;

  @override
  Widget build(BuildContext context) {
    final enrollmentsAsync = ref.watch(enrollmentsProvider);
    final syncState = ref.watch(syncControllerProvider);
    final isSyncing = syncState.values.any((s) => s.status == SyncStatus.syncing);

    // Auto-trigger an initial sync when there is no cached data yet
    // (e.g. first login). Only do this once per screen lifecycle.
    if (!_autoSyncTriggered && enrollmentsAsync.hasError && !isSyncing) {
      _autoSyncTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(syncControllerProvider.notifier).syncAll();
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Courses'),
        actions: [
          // Global refresh button — spins while any course is syncing.
          if (isSyncing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Refresh courses',
              onPressed: () =>
                  ref.read(syncControllerProvider.notifier).syncAll(),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: enrollmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _EmptyState(
          onSync: () => ref.read(syncControllerProvider.notifier).syncAll(),
        ),
        data: (enrollments) {
          if (enrollments.isEmpty) {
            return _EmptyState(
              message: 'No enrolled courses found.',
              onSync: () =>
                  ref.read(syncControllerProvider.notifier).syncAll(),
            );
          }

          return ListView.builder(
            itemCount: enrollments.length,
            itemBuilder: (context, index) {
              final enrollment = enrollments[index];
              final courseId = enrollment.run.coursewareId;
              final courseSyncState = syncState[courseId];
              return _CourseCard(
                enrollment: enrollment,
                syncState: courseSyncState,
                onRefresh: () => ref
                    .read(syncControllerProvider.notifier)
                    .syncCourse(courseId),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    this.message = 'No courses cached yet.\nConnect to sync.',
    required this.onSync,
  });

  final String message;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.school_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onSync,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
        ],
      ),
    );
  }
}

class _CourseCard extends ConsumerWidget {
  const _CourseCard({
    required this.enrollment,
    required this.syncState,
    required this.onRefresh,
  });

  final Enrollment enrollment;
  final CourseSyncState? syncState;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = enrollment.run;
    final status = syncState?.status ?? SyncStatus.idle;
    final isSyncing = status == SyncStatus.syncing;
    final hasError = status == SyncStatus.error;

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

    final lastSynced = syncState?.lastSyncedAt;
    final syncLabel = isSyncing
        ? 'Syncing…'
        : hasError
            ? 'Sync failed'
            : lastSynced != null
                ? 'Synced ${_relativeTime(lastSynced)}'
                : 'Not synced';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isSyncing
            ? null
            : () => context.push('/course/${run.coursewareId}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(run.courseNumber),
                    if (dateRange != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        dateRange,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (hasError)
                          const Icon(Icons.error_outline,
                              size: 14, color: Colors.red)
                        else if (isSyncing)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        else
                          Icon(Icons.check_circle_outline,
                              size: 14,
                              color: lastSynced != null
                                  ? Colors.green
                                  : Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          syncLabel,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: hasError ? Colors.red : Colors.grey,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Per-course refresh button.
              IconButton(
                icon: isSyncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.sync,
                        color: hasError
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                tooltip: 'Refresh this course',
                onPressed: isSyncing ? null : onRefresh,
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatDate(String? dateStr) {
    if (dateStr == null) return null;
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
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
