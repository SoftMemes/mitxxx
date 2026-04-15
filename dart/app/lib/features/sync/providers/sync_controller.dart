// ignore_for_file: uri_has_not_been_generated
import 'dart:async';
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
// Course-level sync controller
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
class SyncController extends _$SyncController {
  /// Pending sequence queues keyed by courseId. Mutated by [prioritiseSequence]
  /// between awaits — safe in Dart's single-threaded isolate.
  final Map<String, List<String>> _pendingByCourse = {};

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

  /// Syncs all enrolled courses. Re-authenticates LMS session if needed.
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

    await Future.wait(
      enrollments.map((e) => syncCourse(e.run.coursewareId)),
    );

    unawaited(analytics.logSyncComplete(
      scope: kScopeAllCourses,
      durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      itemsSynced: enrollments.length,
    ));
  }

  /// Syncs a single course using a two-phase approach:
  /// Phase 1 — fetch outline and surface the sequence list immediately.
  /// Phase 2 — sync sequence content one at a time, in course order.
  Future<void> syncCourse(String courseId, {String trigger = kTriggerManual}) async {
    _updateCourseState(courseId, SyncStatus.syncing);

    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final analytics = ref.read(analyticsServiceProvider);
    final seqSync = ref.read(sequenceSyncControllerProvider.notifier);
    final startedAt = DateTime.now();

    unawaited(analytics.logSyncStart(
      scope: kScopeCourse,
      courseId: courseId,
      trigger: trigger,
    ));

    // ── Phase 1: fetch + persist course outline ──────────────────────────────
    List<String> sequenceIds;
    try {
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
      sequenceIds = sections
          .expand<String>((s) =>
              ((s as Map<String, dynamic>)['sequence_ids'] as List? ?? [])
                  .cast<String>())
          .toList();

      // Make the outline screen renderable immediately.
      ref.invalidate(courseOutlineProvider(courseId: courseId));

      // Seed per-sequence state to idle (preserves synced rows from a prior run).
      for (final seqId in sequenceIds) {
        final existing = ref.read(sequenceSyncControllerProvider)[seqId];
        if (existing?.status != SequenceSyncStatus.synced) {
          seqSync.setSequenceState(seqId, const SequenceSyncState());
        }
      }
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

    // ── Phase 2: sync sequences one at a time ────────────────────────────────
    _pendingByCourse[courseId] = List<String>.from(sequenceIds);
    final allVerticalIds = <String>[];

    while (_pendingByCourse[courseId]?.isNotEmpty ?? false) {
      final seqId = _pendingByCourse[courseId]!.removeAt(0);

      // Skip if already synced this run (e.g. after a prioritise jump).
      final currentStatus =
          ref.read(sequenceSyncControllerProvider)[seqId]?.status;
      if (currentStatus == SequenceSyncStatus.synced) continue;

      seqSync.setSequenceState(seqId, const SequenceSyncState(status: SequenceSyncStatus.syncing));

      try {
        // Fetch sequence (vertical list).
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
        final vertIds = items.map((item) => item['id'] as String).toList();
        allVerticalIds.addAll(vertIds);

        // Fetch each vertical's xblock content sequentially.
        for (final vertId in vertIds) {
          await _fetchAndCacheXblock(client, db, vertId, courseId: courseId, retry: true);
        }

        // Make the sequence and its xblocks live immediately.
        ref.invalidate(sequenceDetailProvider(blockId: seqId));
        for (final vertId in vertIds) {
          ref.invalidate(xblockContentProvider(blockId: vertId));
        }

        final now = DateTime.now();
        seqSync.setSequenceState(
          seqId,
          SequenceSyncState(status: SequenceSyncStatus.synced, lastSyncedAt: now),
        );
      } on Object catch (e, st) {
        _log.warning('syncCourse($courseId): sequence $seqId failed', e, st);
        final errorMsg = e.toString();
        seqSync.setSequenceState(
          seqId,
          SequenceSyncState(status: SequenceSyncStatus.error, errorMessage: errorMsg),
        );
        unawaited(analytics.logSyncFailure(
          scope: kScopeCourse,
          courseId: courseId,
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
          stage: 'sequence',
          errorKind: e is DioException ? 'network' : 'unknown',
        ));
        // Continue with remaining sequences.
      }
    }

    _pendingByCourse.remove(courseId);

    // Cleanup and finalise.
    await _cleanupRemovedVideos(db, courseId, allVerticalIds);
    final now = DateTime.now();
    await db.putSyncSuccess(courseId, now);
    _updateCourseState(courseId, SyncStatus.idle, lastSyncedAt: now);
    unawaited(analytics.logSyncComplete(
      scope: kScopeCourse,
      courseId: courseId,
      durationMs: DateTime.now().difference(startedAt).inMilliseconds,
      itemsSynced: allVerticalIds.length,
    ));
  }

  /// Moves [sequenceId] to the front of the pending queue for [courseId].
  ///
  /// If the sequence is already synced, this is a no-op.
  /// If no sync is currently running for the course, starts one.
  void prioritiseSequence(String courseId, String sequenceId) {
    final seqState = ref.read(sequenceSyncControllerProvider)[sequenceId];
    if (seqState?.status == SequenceSyncStatus.synced) return;

    final queue = _pendingByCourse[courseId];
    if (queue != null) {
      queue
        ..remove(sequenceId)
        ..insert(0, sequenceId);
    } else {
      // No active sync — start one so the sequence gets fetched.
      _pendingByCourse[courseId] = [sequenceId];
      final courseStatus = state[courseId]?.status;
      if (courseStatus != SyncStatus.syncing) {
        unawaited(syncCourse(courseId));
      }
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
      final cachedXblock = await db.getXblock(verticalId);
      final xblockHeaders = _conditionalHeaders(
        etag: cachedXblock?.etag,
        lastModified: cachedXblock?.lastModified,
      );
      try {
        final resp = await client.lms.get<dynamic>(
          '/xblock/$verticalId',
          options: xblockHeaders != null ? Options(headers: xblockHeaders) : null,
        );
        final html =
            resp.data is String ? resp.data as String : resp.data.toString();
        final videos = extractVideoMetadata(html);
        final content = XBlockContent(
          videos: videos,
          htmlContent: html,
          hasContent: html.trim().isNotEmpty,
        );
        await _detectStaleDownloads(db, verticalId, videos);
        await db.putXblock(
          verticalId,
          jsonEncode(content.toJson()),
          etag: resp.headers.value('etag'),
          lastModified: resp.headers.value('last-modified'),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 304) rethrow;
      }
    } on Object catch (e, st) {
      if (retry) {
        _log.warning('xblock $verticalId failed, retrying', e, st);
        await _fetchAndCacheXblock(client, db, verticalId, courseId: courseId);
      } else {
        _log.warning('xblock $verticalId failed after retry', e, st);
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
