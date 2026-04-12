import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:emajtee/features/courses/providers/enrollments_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrollmentsAsync = ref.watch(enrollmentsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Courses'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: enrollmentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                'Could not load courses',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => ref.invalidate(enrollmentsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (enrollments) {
          if (enrollments.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.school_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No courses',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(enrollmentsProvider),
            child: ListView.builder(
              itemCount: enrollments.length,
              itemBuilder: (context, index) =>
                  _CourseCard(enrollment: enrollments[index]),
            ),
          );
        },
      ),
    );
  }

}

class _CourseCard extends StatelessWidget {
  const _CourseCard({required this.enrollment});

  final Enrollment enrollment;

  @override
  Widget build(BuildContext context) {
    final run = enrollment.run;

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

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(
          run.title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(run.courseNumber),
            if (dateRange != null) ...[
              const SizedBox(height: 4),
              Text(
                dateRange,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/course/${run.coursewareId}'),
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
}
