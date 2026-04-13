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

          return ListView.separated(
            itemCount: enrollments.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final enrollment = enrollments[index];
              final courseId = enrollment.run.coursewareId;
              final courseSyncState = syncState[courseId];
              return _CourseTile(
                enrollment: enrollment,
                syncState: courseSyncState,
                onTap: courseSyncState?.status == SyncStatus.syncing
                    ? null
                    : () => context.push('/course/$courseId'),
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

class _CourseTile extends StatelessWidget {
  const _CourseTile({
    required this.enrollment,
    required this.syncState,
    required this.onTap,
  });

  final Enrollment enrollment;
  final CourseSyncState? syncState;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
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

    final imageUrl = run.course?.featureImageSrc;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Course artwork.
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: imageUrl != null && imageUrl.isNotEmpty
                  ? Image.network(
                      imageUrl,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : _ArtworkPlaceholder(),
                      errorBuilder: (_, __, ___) => _ArtworkPlaceholder(),
                    )
                  : _ArtworkPlaceholder(),
            ),
            const SizedBox(width: 12),

            // Course info.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    run.courseNumber,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                  ),
                  if (dateRange != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      dateRange,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.5),
                          ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (hasError)
                        const Icon(Icons.error_outline,
                            size: 14, color: Colors.red)
                      else if (isSyncing)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child:
                              CircularProgressIndicator(strokeWidth: 1.5),
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
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color:
                                      hasError ? Colors.red : Colors.grey,
                                ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
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

class _ArtworkPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.school_outlined, color: Colors.grey),
    );
  }
}
