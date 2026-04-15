// ignore_for_file: uri_has_not_been_generated
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emajtee/core/analytics/analytics_events.dart';
import 'package:emajtee/core/analytics/analytics_service.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/app_database.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/enrollments_provider.dart';
import 'package:emajtee/features/courses/providers/outline_provider.dart';
import 'package:emajtee/features/courses/providers/sequence_provider.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/courses/utils/xblock_parser.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:logging/logging.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_controller.g.dart';

final _log = Logger('sync');

@Riverpod(keepAlive: true)
class SyncController extends _$SyncController {
  @override
  Map<String, CourseSyncState> build() {
    // Load persisted sync states from DB asynchronously and update state.
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

  /// Syncs all enrolled courses. Re-authenticates LMS session if needed.
  ///
  /// [trigger] is passed through to the analytics event to distinguish
  /// manual sync button taps, auto-syncs on first load, and pull-to-refresh.
  Future<void> syncAll({String trigger = kTriggerManual}) async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeAllCourses,
      trigger: trigger,
    ));

    // Re-validate LMS session before syncing.
    try {
      await client.establishLmsSession();
    } on Object catch (e, st) {
      _log.warning('syncAll: LMS session refresh failed, proceeding anyway', e, st);
    }

    // Fetch enrollment list.
    List<Enrollment> enrollments;
    try {
      final response =
          await client.mitxOnline.get<dynamic>('/api/v1/enrollments/');
      final list = response.data as List<dynamic>;
      await db.putEnrollments(jsonEncode(list));
      enrollments = list
          .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
          .toList();
      // Pre-seed sync states as 'syncing' so cards show spinners the moment
      // the enrollment list appears.
      final seeded = <String, CourseSyncState>{};
      for (final e in list.cast<Map<String, dynamic>>()) {
        final courseId = Enrollment.fromJson(e).run.coursewareId;
        final existing = state[courseId];
        seeded[courseId] = (existing ?? const CourseSyncState())
            .copyWith(status: SyncStatus.syncing);
      }
      state = Map.unmodifiable(seeded);
      // Show the course list immediately — before per-course syncs start.
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

    // Sync all courses in parallel.
    await Future.wait(
      enrollments.map((e) => syncCourse(e.run.coursewareId)),
    );

    unawaited(analytics.logSyncComplete(
      scope: kScopeAllCourses,
      durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      itemsSynced: enrollments.length,
    ));
  }

  /// Syncs a single course's metadata (outline + sequences + xblocks).
  Future<void> syncCourse(String courseId, {String trigger = kTriggerManual}) async {
    _updateCourseState(courseId, SyncStatus.syncing);

    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeCourse,
      courseId: courseId,
      trigger: trigger,
    ));

    try {
      // 1. Fetch and cache course outline.
      final outlineResp = await client.lms.get<dynamic>(
        '/api/learning_sequences/v1/course_outline/$courseId',
      );
      final outlineData = outlineResp.data as Map<String, dynamic>;
      final outlineSection = outlineData['outline'] as Map<String, dynamic>?;
      if ((outlineSection?['sections'] as List? ?? []).isNotEmpty) {
        await db.putOutline(courseId, jsonEncode(outlineData));
      }

      // 2. Collect all sequence IDs from the outline.
      final sections =
          (outlineSection?['sections'] as List? ?? []).cast<dynamic>();
      final sequenceIds = sections
          .expand<String>((s) =>
              ((s as Map<String, dynamic>)['sequence_ids'] as List? ?? [])
                  .cast<String>())
          .toList();

      // 3 + 4. Fetch sequences (producing vertical IDs) and xblocks concurrently.
      //        Verticals are enqueued as soon as their parent sequence returns,
      //        so xblock fetches overlap with remaining sequence fetches.
      final allVerticalIds = <String>[];
      final vertQueue = _AsyncQueue<String>();

      final seqFuture = _parallelBounded(sequenceIds, 8, (seqId) async {
        final seqResp =
            await client.lms.get<dynamic>('/api/courseware/sequence/$seqId');
        final seqData = seqResp.data as Map<String, dynamic>;
        await db.putSequence(seqId, jsonEncode(seqData));

        final items =
            ((seqData['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final vertIds = items.map((item) => item['id'] as String).toList();
        allVerticalIds.addAll(vertIds);
        for (final id in vertIds) { vertQueue.add(id); }
      }).whenComplete(vertQueue.close);

      // Xblock workers drain the queue as vertical IDs arrive from sequences.
      final xblockFuture = Future.wait(
        List.generate(8, (_) async {
          while (true) {
            final vertId = await vertQueue.take();
            if (vertId == null) return;
            await _fetchAndCacheXblock(
              client, db, vertId, courseId: courseId, retry: true,
            );
          }
        }),
      );

      await Future.wait([seqFuture, xblockFuture]);

      // 5. Cleanup: remove downloads for video blocks that no longer exist.
      await _cleanupRemovedVideos(db, courseId, allVerticalIds);

      // 6. Record success; invalidate cached providers for this course.
      final now = DateTime.now();
      await db.putSyncSuccess(courseId, now);
      _updateCourseState(courseId, SyncStatus.idle, lastSyncedAt: now);
      ref.invalidate(courseOutlineProvider(courseId: courseId));
      for (final seqId in sequenceIds) {
        ref.invalidate(sequenceDetailProvider(blockId: seqId));
      }
      for (final vertId in allVerticalIds) {
        ref.invalidate(xblockContentProvider(blockId: vertId));
      }
      unawaited(analytics.logSyncComplete(
        scope: kScopeCourse,
        courseId: courseId,
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        itemsSynced: allVerticalIds.length,
      ));
    } on Object catch (e, st) {
      _log.warning('syncCourse($courseId): failed', e, st);
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
    }
  }

  Future<void> _fetchAndCacheXblock(
    DioClient client,
    AppDatabase db,
    String verticalId, {
    required String courseId,
    bool retry = false,
  }) async {
    try {
      final resp = await client.lms.get<dynamic>('/xblock/$verticalId');
      final html =
          resp.data is String ? resp.data as String : resp.data.toString();
      final videos = extractVideoMetadata(html);
      final content = XBlockContent(
        videos: videos,
        htmlContent: html,
        hasContent: html.trim().isNotEmpty,
      );

      // Detect URL changes: compare old xblock URLs against new ones.
      await _detectStaleDownloads(db, verticalId, videos);

      await db.putXblock(verticalId, jsonEncode(content.toJson()));
    } on Object catch (e, st) {
      if (retry) {
        _log.warning('xblock $verticalId failed, retrying', e, st);
        await _fetchAndCacheXblock(client, db, verticalId, courseId: courseId);
      } else {
        _log.warning('xblock $verticalId failed after retry', e, st);
        // Don't rethrow — a single bad vertical shouldn't fail the whole course.
      }
    }
  }


  /// Compares the old cached xblock's video URLs against [newVideos].
  /// Any old URL that is no longer present and has a downloaded row is
  /// marked stale — the user will see an update-available indicator.
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

      // Old URL is gone — if it was downloaded, mark stale.
      final downloaded = await db.getDownloadedVideo(oldUrl);
      if (downloaded != null &&
          downloaded.status == DownloadStatus.downloaded.name) {
        await db.markDownloadStale(oldUrl);
        _log.info('Marked stale: $oldUrl (vertical $verticalId)');
      }
    }
  }

  /// Removes download rows (and their files) for any URL that belongs to
  /// [courseId] but is no longer present in any of [currentVerticalIds].
  Future<void> _cleanupRemovedVideos(
    AppDatabase db,
    String courseId,
    List<String> currentVerticalIds,
  ) async {
    // Collect all current mp4Urls across the course's xblocks.
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

    // Find downloads for this course that are no longer in the URL set.
    final courseDownloads = await db.getDownloadsForCourse(courseId);
    for (final row in courseDownloads) {
      if (currentUrls.contains(row.url)) continue;
      // This URL is no longer in the course — remove the course reference.
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

  /// Processes [items] with a rolling pool of [concurrency] concurrent workers.
  ///
  /// Unlike a batch-wait approach, a new item starts the moment any worker
  /// finishes — no head-of-line blocking from one slow request.
  Future<void> _parallelBounded<T>(
    Iterable<T> items,
    int concurrency,
    Future<void> Function(T) fn,
  ) async {
    final iter = items.iterator;
    await Future.wait(
      List.generate(concurrency, (_) async {
        // Each worker pulls items one at a time. moveNext() + current are
        // synchronous (no await between them) so they're safe in Dart's
        // single-threaded isolate — no two workers can observe the same item.
        while (iter.moveNext()) {
          final item = iter.current;
          await fn(item);
        }
      }),
    );
  }
}

/// Async FIFO queue for producer-consumer coordination within a single isolate.
///
/// Producers call [add]; consumers call [take] (which suspends until an item
/// is available). Call [close] when no more items will be added — suspended
/// [take] calls will then return null, signalling consumers to stop.
class _AsyncQueue<T> {
  final _items = Queue<T>();
  final _waiters = Queue<Completer<T?>>();
  bool _closed = false;

  void add(T item) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(item);
    } else {
      _items.add(item);
    }
  }

  void close() {
    _closed = true;
    for (final w in _waiters) {
      w.complete(null);
    }
    _waiters.clear();
  }

  /// Returns the next item, or null when the queue is closed and drained.
  Future<T?> take() {
    if (_items.isNotEmpty) return Future.value(_items.removeFirst());
    if (_closed) return Future<T?>.value();
    final c = Completer<T?>();
    _waiters.add(c);
    return c.future;
  }
}
