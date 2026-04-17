// ignore_for_file: uri_has_not_been_generated
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/courses/providers/enrollments_provider.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/courses/providers/sequence_provider.dart';
import 'package:omnilect/features/courses/providers/xblock_provider.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';
import 'package:omnilect/features/downloads/models/download_status.dart';
import 'package:omnilect/features/sync/models/course_sync_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_controller.g.dart';

final _log = Logger('sync');

/// Global concurrency limit across all sync-related network operations
/// (outline fetches, sequence metadata fetches, xblock fetches) — applied
/// across ALL courses currently syncing.
const int kSyncConcurrency = 16;

// ---------------------------------------------------------------------------
// Per-sequence sync state provider
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
class SequenceSyncController extends _$SequenceSyncController {
  @override
  Map<String, SequenceSyncState> build() => const {};

  void setSequenceState(String sequenceId, SequenceSyncState s) {
    state = Map.unmodifiable({...state, sequenceId: s});
  }
}

// ---------------------------------------------------------------------------
// Global priority scheduler
// ---------------------------------------------------------------------------

/// Special sentinel priority values.
const int _kOutlinePriority = -10;   // outlines always run first
const int _kTappedPriority = -1;     // user-prioritised sequences jump the queue
// Regular sequence tasks use priority = sequenceOrderInCourse (0, 1, 2, ...),
// which naturally interleaves sequences from multiple courses at the same
// ordinal position.

class _SyncTask {
  _SyncTask({
    required this.run,
    required this.priority,
    required this.sequenceId,
  });
  final Future<void> Function() run;
  int priority;
  final String sequenceId; // '' when the task is not tied to a sequence
}

/// Shared priority scheduler. At most `concurrency` tasks run concurrently.
/// Tasks are ordered by priority (ascending); ties preserve insertion order.
class _SyncScheduler {
  _SyncScheduler(this.concurrency);
  final int concurrency;
  final List<_SyncTask> _queue = [];
  final Set<String> _prioritisedSeqIds = {};
  int _workers = 0;
  Completer<void>? _idleCompleter;

  void enqueue(_SyncTask task) {
    if (task.sequenceId.isNotEmpty &&
        _prioritisedSeqIds.contains(task.sequenceId)) {
      task.priority = _kTappedPriority;
    }
    var i = 0;
    while (i < _queue.length && _queue[i].priority <= task.priority) {
      i++;
    }
    _queue.insert(i, task);
    _ensureWorkers();
  }

  /// Moves any pending tasks for [sequenceId] to the front of the queue and
  /// records that future tasks for the same sequence should also run early.
  void prioritise(String sequenceId) {
    _prioritisedSeqIds.add(sequenceId);
    var changed = false;
    for (final t in _queue) {
      if (t.sequenceId == sequenceId && t.priority != _kTappedPriority) {
        t.priority = _kTappedPriority;
        changed = true;
      }
    }
    if (changed) {
      // Stable sort: Dart's List.sort is not guaranteed stable, but ties only
      // occur between tasks that already share a priority (e.g. same order),
      // and for our purposes that's fine.
      _queue.sort((a, b) => a.priority.compareTo(b.priority));
    }
  }

  /// Drops all queued tasks. In-flight workers are not cancelled — pair with
  /// [waitForIdle] to wait for them to finish their current task.
  void clearQueue() {
    _queue.clear();
    _prioritisedSeqIds.clear();
  }

  /// Resolves once every worker has finished its current task and the queue
  /// is empty.
  Future<void> waitForIdle() async {
    if (_workers == 0) return;
    _idleCompleter ??= Completer<void>();
    return _idleCompleter!.future;
  }

  void _ensureWorkers() {
    while (_workers < concurrency && _queue.isNotEmpty) {
      _workers++;
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      try {
        await task.run();
      } on Object catch (e, st) {
        _log.warning('scheduler: task crashed', e, st);
      }
    }
    _workers--;
    if (_workers == 0 && _idleCompleter != null) {
      final c = _idleCompleter!;
      _idleCompleter = null;
      c.complete();
    }
  }
}

// ---------------------------------------------------------------------------
// Internal per-sequence + per-course tracking
// ---------------------------------------------------------------------------

class _SeqTracker {
  _SeqTracker({required this.courseId, required this.order});
  final String courseId;
  final int order; // position in course (used as scheduling priority)
  int totalTasks = 0;
  int completedTasks = 0;
  int get pendingTasks => totalTasks - completedTasks;
  bool errored = false;
  String? errorMessage;
}

class _CourseContext {
  _CourseContext({required this.startedAt, required this.completer});
  final DateTime startedAt;
  final Completer<void> completer;
  final Set<String> pendingSeqIds = <String>{};
  final Set<String> allVerticalIds = <String>{};
  int itemsSynced = 0; // populated at finalisation for analytics
}

// ---------------------------------------------------------------------------
// Course-level sync controller
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
class SyncController extends _$SyncController {
  final _SyncScheduler _scheduler = _SyncScheduler(kSyncConcurrency);
  final Map<String, _SeqTracker> _trackers = {};
  final Map<String, _CourseContext> _courses = {};

  @override
  Map<String, CourseSyncState> build() {
    _initFromDb();
    return {};
  }

  Future<void> _initFromDb() async {
    final db = ref.read(appDatabaseProvider);
    final cached = await db.getEnrollments();
    if (cached == null) return;

    final list = jsonDecode(cached.data) as List<dynamic>;
    final enrollments = list
        .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
        .toList();

    final syncStates = <String, CourseSyncState>{};
    for (final enrollment in enrollments) {
      final courseId = enrollment.run.coursewareId;
      final syncData = await db.getSyncState(courseId);
      syncStates[courseId] = CourseSyncState(
        lastSyncedAt: syncData?.lastSyncedAt,
        errorMessage: syncData?.lastError,
        status: syncData?.lastError != null ? SyncStatus.error : SyncStatus.idle,
      );
    }
    state = Map.unmodifiable(syncStates);
  }

  // ── syncAll ────────────────────────────────────────────────────────────────

  Future<void> syncAll({String trigger = kTriggerManual}) async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeAllCourses,
      trigger: trigger,
    ));

    try {
      await client.establishLmsSession();
    } on Object catch (e, st) {
      _log.warning('syncAll: LMS session refresh failed, proceeding anyway', e, st);
    }

    List<Enrollment> enrollments;
    try {
      final response =
          await client.mitxOnline.get<dynamic>('/api/v1/enrollments/');
      final list = response.data as List<dynamic>;
      await db.putEnrollments(jsonEncode(list));
      enrollments = list
          .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
          .toList();
      final seeded = <String, CourseSyncState>{};
      for (final e in list.cast<Map<String, dynamic>>()) {
        final courseId = Enrollment.fromJson(e).run.coursewareId;
        final existing = state[courseId];
        seeded[courseId] = (existing ?? const CourseSyncState())
            .copyWith(status: SyncStatus.syncing);
      }
      state = Map.unmodifiable(seeded);
      ref.invalidate(enrollmentsProvider);
    } on DioException catch (e, st) {
      final status = e.response?.statusCode;
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (status == 401 || status == 403) {
        _log.warning('syncAll: enrollment fetch returned $status — signing out', e, st);
        unawaited(analytics.logSyncFailure(
          scope: kScopeAllCourses,
          durationMs: durationMs,
          stage: 'enrollments',
          errorKind: 'auth',
        ));
        await ref.read(authProvider.notifier).signOut();
        return;
      }
      _log.warning('syncAll: enrollment fetch failed', e, st);
      unawaited(analytics.logSyncFailure(
        scope: kScopeAllCourses,
        durationMs: durationMs,
        stage: 'enrollments',
        errorKind: 'network',
      ));
      return;
    } on Object catch (e, st) {
      _log.warning('syncAll: enrollment fetch failed (non-http)', e, st);
      unawaited(analytics.logSyncFailure(
        scope: kScopeAllCourses,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        stage: 'enrollments',
        errorKind: 'unknown',
      ));
      return;
    }

    // Kick off syncs for every course concurrently — tasks all feed into the
    // single shared scheduler, so total network concurrency is capped at
    // [kSyncConcurrency] regardless of how many courses are enrolled.
    await Future.wait(
      enrollments.map((e) => syncCourse(e.run.coursewareId)),
    );

    unawaited(analytics.logSyncComplete(
      scope: kScopeAllCourses,
      durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      itemsSynced: enrollments.length,
    ));
  }

  // ── syncCourse ─────────────────────────────────────────────────────────────

  /// Schedules sync for a single course through the shared scheduler.
  ///
  /// Phase 1: outline fetch (scheduled with priority [_kOutlinePriority] so it
  /// runs as soon as a worker is free).
  /// Phase 2: all sequences enqueued at once with priority = course-local
  /// order. Each sequence's metadata task, once it completes, enqueues one
  /// xblock task per vertical at the same priority. The sequence stays in
  /// `syncing` state until every one of its metadata + xblock tasks is done.
  Future<void> syncCourse(String courseId, {String trigger = kTriggerManual}) async {
    // Reject duplicate concurrent syncs for the same course.
    if (_courses.containsKey(courseId)) {
      return _courses[courseId]!.completer.future;
    }

    _updateCourseState(courseId, SyncStatus.syncing);

    final analytics = ref.read(analyticsServiceProvider);
    final db = ref.read(appDatabaseProvider);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeCourse,
      courseId: courseId,
      trigger: trigger,
    ));

    // ── Phase 1: outline (through the scheduler). ───────────────────────────
    final outlineReady = Completer<List<String>>();
    _scheduler.enqueue(_SyncTask(
      priority: _kOutlinePriority,
      sequenceId: '',
      run: () async {
        try {
          final ids = await _fetchOutline(courseId);
          if (!outlineReady.isCompleted) outlineReady.complete(ids);
        } on Object catch (e) {
          if (!outlineReady.isCompleted) outlineReady.completeError(e);
        }
      },
    ));

    List<String> sequenceIds;
    try {
      sequenceIds = await outlineReady.future;
    } on Object catch (e, st) {
      _log.warning('syncCourse($courseId): outline fetch failed', e, st);
      final errorMsg = e.toString();
      await db.putSyncError(courseId, errorMsg);
      _updateCourseState(courseId, SyncStatus.error, errorMessage: errorMsg);
      unawaited(analytics.logSyncFailure(
        scope: kScopeCourse,
        courseId: courseId,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        stage: 'outline',
        errorKind: e is DioException ? 'network' : 'unknown',
      ));
      return;
    }

    // Outline is persisted — make the outline screen render immediately.
    ref.invalidate(courseOutlineProvider(courseId: courseId));

    // ── Phase 2: schedule sequences. ────────────────────────────────────────
    final context = _CourseContext(
      startedAt: startedAt,
      completer: Completer<void>(),
    );
    _courses[courseId] = context;

    final seqSync = ref.read(sequenceSyncControllerProvider.notifier);
    final seqStates = ref.read(sequenceSyncControllerProvider);

    // Pre-seed rows to idle (preserving already-synced rows from a prior run).
    for (final seqId in sequenceIds) {
      if (seqStates[seqId]?.status != SequenceSyncStatus.synced) {
        seqSync.setSequenceState(seqId, const SequenceSyncState());
      }
    }

    var scheduled = 0;
    for (var i = 0; i < sequenceIds.length; i++) {
      final seqId = sequenceIds[i];
      if (seqStates[seqId]?.status == SequenceSyncStatus.synced) continue;
      _scheduleSequence(seqId, courseId, order: i);
      scheduled++;
    }

    if (scheduled == 0) {
      // Nothing to do — finalise right away.
      await _finaliseCourse(courseId);
    } else {
      await context.completer.future;
    }

    unawaited(analytics.logSyncComplete(
      scope: kScopeCourse,
      courseId: courseId,
      durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      itemsSynced: context.itemsSynced,
    ));
  }

  // ── syncSequence ───────────────────────────────────────────────────────────

  /// Force re-syncs a single sequence (its metadata + every vertical's xblock
  /// content). Unlike [prioritiseSequence] — which is a "tap-to-queue" helper
  /// that no-ops when already synced — this always re-fetches.
  ///
  /// - If a full course sync is already running for [courseId]: prioritise
  ///   this sequence and await the course sync to finish.
  /// - Otherwise: schedule the sequence standalone (no `_CourseContext`, so
  ///   [_finaliseCourse]'s cleanup pass — which would over-prune downloads
  ///   from sequences it doesn't know about — is skipped) and await its
  ///   terminal state via [sequenceSyncControllerProvider].
  Future<void> syncSequence(
    String courseId,
    String sequenceId, {
    String trigger = kTriggerManual,
  }) async {
    final analytics = ref.read(analyticsServiceProvider);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeSection,
      courseId: courseId,
      trigger: trigger,
    ));

    final courseCtx = _courses[courseId];
    if (courseCtx != null) {
      _scheduler.prioritise(sequenceId);
      await courseCtx.completer.future;
      unawaited(analytics.logSyncComplete(
        scope: kScopeSection,
        courseId: courseId,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        itemsSynced: 1,
      ));
      return;
    }

    if (!_trackers.containsKey(sequenceId)) {
      _scheduleSequence(sequenceId, courseId, order: 0);
    }
    _scheduler.prioritise(sequenceId);

    final terminalCompleter = Completer<SequenceSyncStatus>();
    final sub = ref.listen<Map<String, SequenceSyncState>>(
      sequenceSyncControllerProvider,
      (prev, next) {
        final status = next[sequenceId]?.status;
        if (status == SequenceSyncStatus.synced ||
            status == SequenceSyncStatus.error) {
          if (!terminalCompleter.isCompleted) terminalCompleter.complete(status);
        }
      },
    );

    try {
      final terminal = await terminalCompleter.future;
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      if (terminal == SequenceSyncStatus.synced) {
        unawaited(analytics.logSyncComplete(
          scope: kScopeSection,
          courseId: courseId,
          durationMs: durationMs,
          itemsSynced: 1,
        ));
      } else {
        unawaited(analytics.logSyncFailure(
          scope: kScopeSection,
          courseId: courseId,
          durationMs: durationMs,
          stage: 'sequence',
          errorKind: 'unknown',
        ));
      }
    } finally {
      sub.close();
    }
  }

  /// Stops all in-progress sync work and waits for in-flight workers to
  /// finish their current task. After this resolves no sync task will write
  /// to the DB, so callers can safely clear cached data without risking a
  /// late write resurrecting rows.
  Future<void> stopAll() async {
    _scheduler.clearQueue();
    // Drop trackers and course contexts so any in-flight task completing
    // after this line early-returns in _checkSequenceComplete / _finaliseCourse
    // instead of republishing stale progress.
    _trackers.clear();
    for (final ctx in _courses.values) {
      if (!ctx.completer.isCompleted) ctx.completer.complete();
    }
    _courses.clear();
    state = const {};
    await _scheduler.waitForIdle();
  }

  /// Tap-to-prioritise. Moves every queued task for [sequenceId] to the front
  /// of the global scheduler queue. If no sync is running for the course, it
  /// kicks one off so the sequence actually gets fetched.
  void prioritiseSequence(String courseId, String sequenceId) {
    final seqState = ref.read(sequenceSyncControllerProvider)[sequenceId];
    if (seqState?.status == SequenceSyncStatus.synced) return;

    _scheduler.prioritise(sequenceId);

    // If this sequence isn't currently being tracked AND no sync is active
    // for the course, start one so the sequence reaches the scheduler.
    if (!_trackers.containsKey(sequenceId) &&
        state[courseId]?.status != SyncStatus.syncing) {
      unawaited(syncCourse(courseId));
    }
  }

  // ── Scheduling helpers ─────────────────────────────────────────────────────

  void _publishSeqProgress(String seqId, _SeqTracker t) {
    ref.read(sequenceSyncControllerProvider.notifier).setSequenceState(
      seqId,
      SequenceSyncState(
        status: SequenceSyncStatus.syncing,
        totalTasks: t.totalTasks,
        completedTasks: t.completedTasks,
      ),
    );
  }

  void _scheduleSequence(String seqId, String courseId, {required int order}) {
    final tracker = _SeqTracker(courseId: courseId, order: order);
    _trackers[seqId] = tracker;
    tracker.totalTasks = 1; // metadata fetch
    _courses[courseId]?.pendingSeqIds.add(seqId);

    _publishSeqProgress(seqId, tracker);

    _scheduler.enqueue(_SyncTask(
      priority: order,
      sequenceId: seqId,
      run: () => _runSequenceMetadata(seqId),
    ));
  }

  Future<void> _runSequenceMetadata(String seqId) async {
    final tracker = _trackers[seqId];
    if (tracker == null) return;

    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

    var vertIds = <String>[];
    try {
      final cachedSeq = await db.getSequence(seqId);
      final seqHeaders = _conditionalHeaders(
        etag: cachedSeq?.etag,
        lastModified: cachedSeq?.lastModified,
      );
      Map<String, dynamic> seqData;
      try {
        final seqResp = await client.lms.get<dynamic>(
          '/api/courseware/sequence/$seqId',
          options: seqHeaders != null ? Options(headers: seqHeaders) : null,
        );
        seqData = seqResp.data as Map<String, dynamic>;
        await db.putSequence(
          seqId,
          jsonEncode(seqData),
          etag: seqResp.headers.value('etag'),
          lastModified: seqResp.headers.value('last-modified'),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 304 && cachedSeq != null) {
          seqData = jsonDecode(cachedSeq.data) as Map<String, dynamic>;
        } else {
          rethrow;
        }
      }
      final items =
          ((seqData['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      vertIds = items.map((item) => item['id'] as String).toList();
    } on Object catch (e, st) {
      _log.warning('sequence metadata $seqId failed', e, st);
      tracker
        ..errored = true
        ..errorMessage = e.toString();
    }

    ref.invalidate(sequenceDetailProvider(blockId: seqId));

    // Atomic transition: mark metadata complete, then enqueue xblock tasks
    // before _checkSequenceComplete runs (so the sequence doesn't briefly
    // flip to synced between the two steps).
    tracker.completedTasks++;
    if (!tracker.errored) {
      _courses[tracker.courseId]?.allVerticalIds.addAll(vertIds);
      for (final vertId in vertIds) {
        tracker.totalTasks++;
        _scheduler.enqueue(_SyncTask(
          priority: tracker.order,
          sequenceId: seqId,
          run: () => _runXblock(vertId, tracker.courseId, seqId),
        ));
      }
    }
    _publishSeqProgress(seqId, tracker);
    _checkSequenceComplete(seqId);
  }

  Future<void> _runXblock(String vertId, String courseId, String seqId) async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final tracker = _trackers[seqId];
    try {
      await _fetchAndCacheXblock(client, db, vertId, courseId: courseId, retry: true);
    } on Object catch (e, st) {
      _log.warning('xblock $vertId failed', e, st);
      tracker
        ?..errored = true
        ..errorMessage = e.toString();
    }
    ref.invalidate(xblockContentProvider(blockId: vertId));

    if (tracker == null) return;
    // Always increment so pendingTasks drains and the sequence can transition
    // out of syncing — _checkSequenceComplete branches on tracker.errored to
    // decide between synced and error.
    tracker.completedTasks++;
    _publishSeqProgress(seqId, tracker);
    _checkSequenceComplete(seqId);
  }

  void _checkSequenceComplete(String seqId) {
    final tracker = _trackers[seqId];
    if (tracker == null) return;
    if (tracker.pendingTasks > 0) return;

    final seqSync = ref.read(sequenceSyncControllerProvider.notifier);
    if (tracker.errored) {
      seqSync.setSequenceState(
        seqId,
        SequenceSyncState(
          status: SequenceSyncStatus.error,
          errorMessage: tracker.errorMessage,
        ),
      );
    } else {
      seqSync.setSequenceState(
        seqId,
        SequenceSyncState(
          status: SequenceSyncStatus.synced,
          lastSyncedAt: DateTime.now(),
        ),
      );
    }

    _trackers.remove(seqId);
    final courseId = tracker.courseId;
    final ctx = _courses[courseId];
    ctx?.pendingSeqIds.remove(seqId);

    if (ctx != null && ctx.pendingSeqIds.isEmpty) {
      unawaited(_finaliseCourse(courseId));
    }
  }

  Future<void> _finaliseCourse(String courseId) async {
    final ctx = _courses.remove(courseId);
    if (ctx == null) return;
    final db = ref.read(appDatabaseProvider);
    final verts = ctx.allVerticalIds.toList();
    ctx.itemsSynced = verts.length;
    try {
      await _cleanupRemovedVideos(db, courseId, verts);
    } on Object catch (e, st) {
      _log.warning('cleanup failed for $courseId', e, st);
    }
    final now = DateTime.now();
    await db.putSyncSuccess(courseId, now);
    _updateCourseState(courseId, SyncStatus.idle, lastSyncedAt: now);
    if (!ctx.completer.isCompleted) ctx.completer.complete();
  }

  // ── Network helpers ────────────────────────────────────────────────────────

  /// Fetches + persists the course outline and returns its sequence IDs in
  /// course order. Throws on network failure.
  Future<List<String>> _fetchOutline(String courseId) async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

    final cachedOutline = await db.getOutline(courseId);
    final outlineHeaders = _conditionalHeaders(
      etag: cachedOutline?.etag,
      lastModified: cachedOutline?.lastModified,
    );
    Map<String, dynamic> outlineData;
    try {
      final outlineResp = await client.lms.get<dynamic>(
        '/api/learning_sequences/v1/course_outline/$courseId',
        options: outlineHeaders != null ? Options(headers: outlineHeaders) : null,
      );
      outlineData = outlineResp.data as Map<String, dynamic>;
      final outlineSection = outlineData['outline'] as Map<String, dynamic>?;
      if ((outlineSection?['sections'] as List? ?? []).isNotEmpty) {
        await db.putOutline(
          courseId,
          jsonEncode(outlineData),
          etag: outlineResp.headers.value('etag'),
          lastModified: outlineResp.headers.value('last-modified'),
        );
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 304 && cachedOutline != null) {
        outlineData = jsonDecode(cachedOutline.data) as Map<String, dynamic>;
      } else {
        rethrow;
      }
    }
    final outlineSection = outlineData['outline'] as Map<String, dynamic>?;
    final sections =
        (outlineSection?['sections'] as List? ?? []).cast<dynamic>();
    return sections
        .expand<String>(
          (s) => ((s as Map<String, dynamic>)['sequence_ids'] as List? ?? [])
              .cast<String>(),
        )
        .toList();
  }

  Future<void> _fetchAndCacheXblock(
    DioClient client,
    AppDatabase db,
    String verticalId, {
    required String courseId,
    bool retry = false,
  }) async {
    try {
      final cachedXblock = await db.getXblock(verticalId);
      final xblockHeaders = _conditionalHeaders(
        etag: cachedXblock?.etag,
        lastModified: cachedXblock?.lastModified,
      );
      final Response<dynamic> resp;
      try {
        resp = await client.lms.get<dynamic>(
          '/xblock/$verticalId',
          options: xblockHeaders != null ? Options(headers: xblockHeaders) : null,
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 304) return;
        rethrow;
      }
      final html =
          resp.data is String ? resp.data as String : resp.data.toString();
      final videos = extractVideoMetadata(html);
      final content = XBlockContent(
        videos: videos,
        htmlContent: html,
        hasContent: html.trim().isNotEmpty,
      );
      // Stale-download detection is a side effect — don't let it fail the
      // xblock sync.
      try {
        await _detectStaleDownloads(db, verticalId, videos);
      } on Object catch (e, st) {
        _log.warning('stale-download detection failed for $verticalId', e, st);
      }
      // Critical persistence step — must succeed for the vertical to count
      // as synced. Errors propagate.
      await db.putXblock(
        verticalId,
        jsonEncode(content.toJson()),
        etag: resp.headers.value('etag'),
        lastModified: resp.headers.value('last-modified'),
      );
      // Eagerly populate the sanitized-HTML cache so lecture opens don't
      // pay the DOM-parse cost on first access. Non-critical — the xblock
      // is already cached above; the sanitizer will run lazily on open if
      // this fails.
      try {
        await db.putSanitizedXblock(
          blockId: verticalId,
          safeHtml: sanitizeXBlockHtml(html),
          sanitizerVersion: kSanitizerVersion,
        );
      } on Object catch (e, st) {
        _log.warning('sanitized-html cache warmup failed for $verticalId', e, st);
      }
    } on Object catch (e, st) {
      if (retry) {
        _log.warning('xblock $verticalId failed, retrying', e, st);
        await _fetchAndCacheXblock(client, db, verticalId, courseId: courseId);
      } else {
        _log.warning('xblock $verticalId failed after retry', e, st);
        rethrow;
      }
    }
  }

  Future<void> _detectStaleDownloads(
    AppDatabase db,
    String verticalId,
    List<ParsedVideoBlock> newVideos,
  ) async {
    final oldRow = await db.getXblock(verticalId);
    if (oldRow == null) return;

    XBlockContent oldContent;
    try {
      oldContent = XBlockContent.fromJson(
          jsonDecode(oldRow.data) as Map<String, dynamic>);
    } on Object catch (_) {
      return;
    }

    final newUrls = newVideos
        .where((v) => v.mp4Url != null)
        .map((v) => v.mp4Url!)
        .toSet();

    for (final oldVideo in oldContent.videos) {
      final oldUrl = oldVideo.mp4Url;
      if (oldUrl == null) continue;
      if (newUrls.contains(oldUrl)) continue;
      final downloaded = await db.getDownloadedVideo(oldUrl);
      if (downloaded != null &&
          downloaded.status == DownloadStatus.downloaded.name) {
        await db.markDownloadStale(oldUrl);
        _log.info('Marked stale: $oldUrl (vertical $verticalId)');
      }
    }
  }

  Future<void> _cleanupRemovedVideos(
    AppDatabase db,
    String courseId,
    List<String> currentVerticalIds,
  ) async {
    final currentUrls = <String>{};
    for (final vertId in currentVerticalIds) {
      final row = await db.getXblock(vertId);
      if (row == null) continue;
      try {
        final content = XBlockContent.fromJson(
            jsonDecode(row.data) as Map<String, dynamic>);
        for (final v in content.videos) {
          if (v.mp4Url != null) currentUrls.add(v.mp4Url!);
        }
      } on Object catch (_) {}
    }

    final courseDownloads = await db.getDownloadsForCourse(courseId);
    for (final row in courseDownloads) {
      if (currentUrls.contains(row.url)) continue;
      final orphanedPath =
          await db.removeCourseFromDownload(row.url, courseId);
      if (orphanedPath != null && orphanedPath.isNotEmpty) {
        try {
          File(orphanedPath).deleteSync();
          _log.info('Deleted orphaned download: $orphanedPath');
        } on Object catch (e) {
          _log.warning('Could not delete orphaned file $orphanedPath: $e');
        }
      }
    }
  }

  Map<String, String>? _conditionalHeaders({
    String? etag,
    String? lastModified,
  }) {
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;
    if (lastModified != null) headers['If-Modified-Since'] = lastModified;
    return headers.isEmpty ? null : headers;
  }

  void _updateCourseState(
    String courseId,
    SyncStatus status, {
    DateTime? lastSyncedAt,
    String? errorMessage,
  }) {
    final existing = state[courseId];
    state = Map.unmodifiable({
      ...state,
      courseId: CourseSyncState(
        status: status,
        lastSyncedAt: lastSyncedAt ?? existing?.lastSyncedAt,
        errorMessage: errorMessage,
      ),
    });
  }
}
