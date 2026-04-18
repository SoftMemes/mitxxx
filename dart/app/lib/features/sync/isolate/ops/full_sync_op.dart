import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/sync/isolate/ops/course_sync_runner.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/ops/op_helpers.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

final _log = Logger('sync.full');

class FullSyncOp extends LogicalOp {
  FullSyncOp({
    required super.request,
    required super.cancelToken,
    required super.events,
    required this.ctx,
  });

  final OpContext ctx;

  @override
  Future<void> run() async {
    final runtime = OpRuntime(ctx: ctx, token: cancelToken, events: events);
    final started = DateTime.now();

    runtime.analytics.logSyncStart(
      scope: 'all_courses',
      trigger: trigger,
    );

    _publishScope(runtime, ScopeIds.allCourses,
        const ScopeState(status: ScopeStatus.syncing));

    // Fetch enrollments.
    List<Enrollment> enrollments;
    try {
      enrollments = await fetchEnrollments(runtime);
    } on StaleSessionException {
      _publishScope(runtime, ScopeIds.allCourses, const ScopeState());
      rethrow;
    } on Object catch (e, st) {
      _log.warning('fullSync: enrollment fetch failed', e, st);
      _publishScope(
        runtime,
        ScopeIds.allCourses,
        ScopeState(
          status: ScopeStatus.error,
          errorMessage: e.toString(),
        ),
      );
      runtime.analytics.logSyncFailure(
        scope: 'all_courses',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'enrollments',
        errorKind: 'network',
      );
      return;
    }

    runtime.events.add(const DbInvalidated('enrollments'));
    if (enrollments.isNotEmpty) {
      final imgUrls = <String>{
        for (final e in enrollments)
          if ((e.run.course?.featureImageSrc ?? '').isNotEmpty)
            e.run.course!.featureImageSrc!,
      }.toList();
      if (imgUrls.isNotEmpty) {
        runtime.events.add(PrefetchCourseImages(imgUrls));
      }
    }

    // Reconcile memberships.
    Set<String> targetCourseIds;
    try {
      targetCourseIds = await reconcileMembership(runtime, enrollments);
    } on StaleSessionException {
      _publishScope(runtime, ScopeIds.allCourses, const ScopeState());
      rethrow;
    } on Object catch (e, st) {
      _log.warning('fullSync: reconciliation failed', e, st);
      _publishScope(
        runtime,
        ScopeIds.allCourses,
        ScopeState(
          status: ScopeStatus.error,
          errorMessage: e.toString(),
        ),
      );
      runtime.analytics.logSyncFailure(
        scope: 'all_courses',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'reconcile',
        errorKind: 'unknown',
      );
      return;
    }

    if (targetCourseIds.isEmpty) {
      _log.info('fullSync: empty target set');
      _publishScope(
        runtime,
        ScopeIds.allCourses,
        ScopeState(lastSyncedAt: DateTime.now()),
      );
      runtime.analytics.logSyncComplete(
        scope: 'all_courses',
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );
      return;
    }

    // Pre-seed every target course's scope as scheduled so UI tiles shimmer.
    for (final courseId in targetCourseIds) {
      _publishScope(
        runtime,
        ScopeIds.course(courseId),
        const ScopeState(status: ScopeStatus.scheduled),
      );
    }

    // Sync each course in parallel (each course itself caps its sub-task
    // concurrency via kSyncConcurrency inside syncSingleCourse).
    await Future.wait(targetCourseIds.map((courseId) async {
      if (runtime.token.isCancelled) return;
      try {
        await syncSingleCourse(
          runtime,
          courseId: courseId,
          trigger: trigger,
        );
      } on StaleSessionException {
        rethrow;
      } on Object catch (e, st) {
        _log.warning('fullSync: course $courseId failed', e, st);
      }
    }));

    if (runtime.token.isCancelled) return;

    _publishScope(
      runtime,
      ScopeIds.allCourses,
      ScopeState(lastSyncedAt: DateTime.now()),
    );

    runtime.analytics.logSyncComplete(
      scope: 'all_courses',
      durationMs: DateTime.now().difference(started).inMilliseconds,
      itemsSynced: targetCourseIds.length,
    );
  }

  void _publishScope(OpRuntime r, String scope, ScopeState s) {
    r.events.add(ScopeStateChanged(scope, s));
  }
}
