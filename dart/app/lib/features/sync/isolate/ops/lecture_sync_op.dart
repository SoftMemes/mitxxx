import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/ops/course_sync_runner.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/ops/op_helpers.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

final _log = Logger('sync.lecture');

/// Refresh a single lecture — re-fetch the sequence's metadata and every
/// xblock within it. OCW courses have no sequence tree, so for an OCW
/// [courseId] we delegate to a course-level sync instead.
class LectureSyncOp extends LogicalOp {
  LectureSyncOp({
    required super.request,
    required super.cancelToken,
    required super.events,
    required this.ctx,
    required this.courseId,
    required this.sequenceId,
  });

  final OpContext ctx;
  final String courseId;
  final String sequenceId;

  @override
  Future<void> run() async {
    final runtime = OpRuntime(ctx: ctx, token: cancelToken, events: events);

    if (courseId.startsWith('ocw:')) {
      // OCW: no sequence tree, fall back to course-level sync.
      await syncSingleCourse(runtime, courseId: courseId, trigger: trigger);
      return;
    }

    final scope = ScopeIds.lecture(sequenceId);
    final started = DateTime.now();

    runtime.analytics.logSyncStart(
      scope: 'section',
      courseId: courseId,
      trigger: trigger,
    );
    runtime.events.add(ScopeStateChanged(
      scope,
      const ScopeState(status: ScopeStatus.syncing),
    ));

    // A stale LMS session would silently return trimmed sequence data and
    // 302-to-login on xblock fetches, both surfacing as "no videos / no
    // content" in the UI. Probe up-front so the manager can re-auth.
    try {
      await ensureFreshLmsSession(runtime);
    } on StaleSessionException {
      runtime.events.add(ScopeStateChanged(scope, const ScopeState()));
      rethrow;
    }

    List<String> vertIds;
    try {
      vertIds = await fetchSequenceMetadata(runtime, sequenceId);
    } on StaleSessionException {
      rethrow;
    } on Object catch (e, st) {
      _log.warning('lectureSync($sequenceId): metadata failed', e, st);
      await runtime.ctx.db
          .putLectureSyncError(sequenceId, courseId, e.toString());
      runtime.events.add(ScopeStateChanged(
        scope,
        ScopeState(status: ScopeStatus.error, errorMessage: e.toString()),
      ));
      runtime.analytics.logSyncFailure(
        scope: 'section',
        courseId: courseId,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'sequence',
        errorKind: 'network',
      );
      return;
    }

    final total = vertIds.length + 1;
    var completed = 1;
    runtime.events.add(SubtaskProgress(scope, completed, total));

    var hadError = false;
    for (final vertId in vertIds) {
      if (cancelToken.isCancelled) return;
      try {
        await fetchAndCacheXblock(runtime, vertId, courseId: courseId);
      } on StaleSessionException {
        rethrow;
      } on Object catch (e, st) {
        _log.warning('lectureSync xblock $vertId failed', e, st);
        hadError = true;
      }
      completed++;
      runtime.events.add(SubtaskProgress(scope, completed, total));
    }

    if (hadError) {
      await runtime.db.putLectureSyncError(
        sequenceId,
        courseId,
        'Some content failed to sync',
      );
      runtime.events.add(ScopeStateChanged(
        scope,
        const ScopeState(
          status: ScopeStatus.error,
          errorMessage: 'Some content failed to sync',
        ),
      ));
      runtime.analytics.logSyncFailure(
        scope: 'section',
        courseId: courseId,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'xblocks',
        errorKind: 'unknown',
      );
    } else {
      final now = DateTime.now();
      await runtime.db.putLectureSyncSuccess(sequenceId, courseId, now);
      runtime.events.add(ScopeStateChanged(
        scope,
        ScopeState(lastSyncedAt: now),
      ));
      runtime.analytics.logSyncComplete(
        scope: 'section',
        courseId: courseId,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        itemsSynced: vertIds.length,
      );
    }
  }
}
