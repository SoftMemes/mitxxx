import 'dart:async';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/ops/op_helpers.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

final _log = Logger('sync.course');

/// Runs the per-course sync work for a single course. Used by both
/// `CourseSyncOp` (directly) and `FullSyncOp` (looped per course).
///
/// Emits [ScopeStateChanged] events for the course and each of its sequences
/// to drive in-memory status/progress. Persistent `lastSyncedAt` /
/// `lastError` are written to the DB (`cached_course_sync` /
/// `cached_lecture_sync`) and surfaced to the UI via
/// [DbInvalidated] — the bridge invalidates `courseSyncRecordProvider` /
/// `lectureSyncRecordProvider`, which the combined UI provider recombines
/// with in-memory status. Sub-task errors are logged and per-scope error
/// state is published; only [StaleSessionException] aborts the whole course
/// sync.
Future<CourseSyncOutcome> syncSingleCourse(
  OpRuntime r, {
  required String courseId,
  required String trigger,
}) async {
  final scope = ScopeIds.course(courseId);
  final started = DateTime.now();
  final isOcw = courseId.startsWith('ocw:');

  _log.info('syncCourse: START $courseId');
  _publishScope(r, scope, const ScopeState(status: ScopeStatus.syncing));

  r.analytics.logSyncStart(
    scope: 'course',
    courseId: courseId,
    trigger: trigger,
  );

  // OCW courses download in a single API call, so honest progress is only
  // "fetching / done". Seed 0/1 up-front so the course-row progress bar
  // shows an empty state during the fetch; we flip to 1/1 at finalise.
  // MITx progress is seeded below once we know the sequence count.
  if (isOcw) {
    _publishSubtaskProgress(r, scope, 0, 1);
  }

  // Phase 1: outline.
  List<String> sequenceIds;
  try {
    sequenceIds = await fetchOutline(r, courseId);
  } on StaleSessionException {
    rethrow;
  } on Object catch (e, st) {
    _log.warning('syncCourse($courseId): outline fetch failed', e, st);
    await r.db.putSyncError(courseId, e.toString());
    r.events.add(DbInvalidated('courseSync', courseId));
    _publishScope(r, scope, const ScopeState(status: ScopeStatus.error));
    r.analytics.logSyncFailure(
      scope: 'course',
      courseId: courseId,
      durationMs: DateTime.now().difference(started).inMilliseconds,
      stage: 'outline',
      errorKind: 'network',
    );
    return CourseSyncOutcome.errored;
  }

  r.events.add(DbInvalidated('courseOutline', courseId));

  if (sequenceIds.isEmpty) {
    // OCW (no sequence tree) — already done inside fetchOutline.
    _publishSubtaskProgress(r, scope, 1, 1);
    await _finaliseCourse(r, courseId, const [], started);
    return CourseSyncOutcome.completed;
  }

  // Phase 2: sequences + xblocks, bounded concurrency.
  final totalSeqs = sequenceIds.length;
  var doneSeqs = 0;
  _publishSubtaskProgress(r, scope, doneSeqs, totalSeqs);

  final collectedVerticalIds = <String>[];
  final collectedVerticalsLock = <String>{};
  var hadError = false;

  await _runBounded<String>(
    items: sequenceIds,
    concurrency: kSyncConcurrency,
    cancelToken: r.token,
    work: (sequenceId) async {
      if (r.token.isCancelled) return;
      final lectureScope = ScopeIds.lecture(sequenceId);
      _publishScope(
        r,
        lectureScope,
        const ScopeState(status: ScopeStatus.syncing),
      );

      try {
        List<String> vertIds;
        try {
          vertIds = await fetchSequenceMetadata(r, sequenceId);
        } on StaleSessionException {
          rethrow;
        } on Object catch (e, st) {
          _log.warning('sequence $sequenceId failed', e, st);
          hadError = true;
          await r.db.putLectureSyncError(
            sequenceId,
            courseId,
            _shortErrorMessage(e),
          );
          r.events.add(DbInvalidated('lectureSync', sequenceId));
          _publishScope(
            r,
            lectureScope,
            const ScopeState(status: ScopeStatus.error),
          );
          return;
        }

        for (final v in vertIds) {
          if (!collectedVerticalsLock.add(v)) continue;
          collectedVerticalIds.add(v);
        }

        final total = vertIds.length + 1;
        var completed = 1;
        _publishSubtaskProgress(r, lectureScope, completed, total);

        var sequenceErrored = false;
        for (final vertId in vertIds) {
          if (r.token.isCancelled) break;
          try {
            await fetchAndCacheXblock(r, vertId, courseId: courseId);
          } on StaleSessionException {
            rethrow;
          } on Object catch (e, st) {
            _log.warning('xblock $vertId failed', e, st);
            sequenceErrored = true;
            hadError = true;
          }
          completed++;
          _publishSubtaskProgress(r, lectureScope, completed, total);
        }

        if (sequenceErrored) {
          await r.db.putLectureSyncError(
            sequenceId,
            courseId,
            'One or more content blocks failed to sync',
          );
          r.events.add(DbInvalidated('lectureSync', sequenceId));
          _publishScope(
            r,
            lectureScope,
            const ScopeState(status: ScopeStatus.error),
          );
        } else {
          final now = DateTime.now();
          await r.db.putLectureSyncSuccess(sequenceId, courseId, now);
          r.events.add(DbInvalidated('lectureSync', sequenceId));
          _publishScope(r, lectureScope, const ScopeState());
        }
      } finally {
        // Tick the course-scope progress bar once per sequence, regardless
        // of success or per-lecture error — the lecture is "done" from the
        // course's point of view either way. Cancelled workers skip the
        // tick so we don't count aborted work.
        if (!r.token.isCancelled) {
          doneSeqs++;
          _publishSubtaskProgress(r, scope, doneSeqs, totalSeqs);
        }
      }
    },
  );

  if (r.token.isCancelled) {
    _log.info('syncCourse: CANCELLED $courseId');
    return CourseSyncOutcome.cancelled;
  }

  await _finaliseCourse(r, courseId, collectedVerticalIds, started);

  final durationMs = DateTime.now().difference(started).inMilliseconds;
  _log.info(
    'syncCourse: COMPLETE $courseId '
    '(${collectedVerticalIds.length} verticals, hadError=$hadError, '
    '${durationMs}ms)',
  );

  r.analytics.logSyncComplete(
    scope: 'course',
    courseId: courseId,
    durationMs: durationMs,
    itemsSynced: collectedVerticalIds.length,
  );

  return hadError ? CourseSyncOutcome.partialError : CourseSyncOutcome.completed;
}

Future<void> _finaliseCourse(
  OpRuntime r,
  String courseId,
  List<String> verts,
  DateTime started,
) async {
  try {
    await cleanupRemovedVideos(r, courseId, verts);
  } on Object catch (e, st) {
    _log.warning('cleanup failed for $courseId', e, st);
  }
  final now = DateTime.now();
  await r.db.putSyncSuccess(courseId, now);
  r.events.add(DbInvalidated('courseSync', courseId));
  _publishScope(r, ScopeIds.course(courseId), const ScopeState());
  r.events.add(ValidateTrackedLecture(courseId));
}

void _publishScope(OpRuntime r, String scope, ScopeState state) {
  if (scope.startsWith('lecture:')) {
    _log.info('emit ScopeStateChanged $scope status=${state.status}');
  }
  r.events.add(ScopeStateChanged(scope, state));
}

void _publishSubtaskProgress(
  OpRuntime r,
  String scope,
  int completed,
  int total,
) {
  r.events.add(SubtaskProgress(scope, completed, total));
}

String _shortErrorMessage(Object e) {
  final s = e.toString();
  if (s.length > 200) return '${s.substring(0, 200)}…';
  return s;
}

/// Run [work] across [items] with a maximum of [concurrency] at a time.
/// A [StaleSessionException] from any worker short-circuits the rest.
Future<void> _runBounded<T>({
  required List<T> items,
  required int concurrency,
  required CancelToken cancelToken,
  required Future<void> Function(T) work,
}) async {
  final iter = items.iterator;
  StaleSessionException? staleHit;

  Future<void> worker() async {
    while (true) {
      if (staleHit != null) return;
      if (cancelToken.isCancelled) return;
      if (!iter.moveNext()) return;
      final item = iter.current;
      try {
        await work(item);
      } on StaleSessionException catch (e) {
        staleHit = e;
        return;
      }
    }
  }

  final workers = List.generate(
    items.isEmpty ? 0 : (items.length < concurrency ? items.length : concurrency),
    (_) => worker(),
  );
  await Future.wait(workers);
  if (staleHit != null) throw staleHit!;
}

enum CourseSyncOutcome { completed, partialError, errored, cancelled }
