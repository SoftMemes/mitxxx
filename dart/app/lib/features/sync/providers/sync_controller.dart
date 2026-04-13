// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:emajtee/core/network/dio_client_provider.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/enrollment.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/courses/providers/enrollments_provider.dart';
import 'package:emajtee/features/courses/providers/outline_provider.dart';
import 'package:emajtee/features/courses/providers/sequence_provider.dart';
import 'package:emajtee/features/courses/providers/xblock_provider.dart';
import 'package:emajtee/features/auth/providers/auth_provider.dart';
import 'package:emajtee/features/courses/utils/xblock_parser.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:emajtee/features/sync/models/course_sync_state.dart';
import 'package:logging/logging.dart';
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
  Future<void> syncAll() async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

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
      if (status == 401 || status == 403) {
        _log.warning('syncAll: enrollment fetch returned $status — signing out', e, st);
        await ref.read(authProvider.notifier).signOut();
        return;
      }
      _log.warning('syncAll: enrollment fetch failed', e, st);
      return;
    } on Object catch (e, st) {
      _log.warning('syncAll: enrollment fetch failed (non-http)', e, st);
      return;
    }

    // Sync all courses in parallel.
    await Future.wait(
      enrollments.map((e) => syncCourse(e.run.coursewareId)),
      eagerError: false,
    );
  }

  /// Syncs a single course's metadata (outline + sequences + xblocks).
  Future<void> syncCourse(String courseId) async {
    _updateCourseState(courseId, SyncStatus.syncing);

    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);

    try {
      // 1. Fetch and cache course outline.
      final outlineResp = await client.lms.get<dynamic>(
        '/api/learning_sequences/v1/course_outline/$courseId',
      );
      final outlineData = outlineResp.data as Map<String, dynamic>;
      if ((outlineData['outline']?['sections'] as List? ?? []).isNotEmpty) {
        await db.putOutline(courseId, jsonEncode(outlineData));
      }

      // 2. Collect all sequence IDs from the outline.
      final sections =
          (outlineData['outline']?['sections'] as List? ?? []).cast<dynamic>();
      final sequenceIds = sections
          .expand<String>((s) =>
              ((s as Map<String, dynamic>)['sequence_ids'] as List? ?? [])
                  .cast<String>())
          .toList();

      // 3. Fetch all sequences; collect vertical IDs.
      final allVerticalIds = <String>[];
      await _parallelBounded(sequenceIds, 4, (seqId) async {
        final seqResp =
            await client.lms.get<dynamic>('/api/courseware/sequence/$seqId');
        final seqData = seqResp.data as Map<String, dynamic>;
        await db.putSequence(seqId, jsonEncode(seqData));

        final items =
            ((seqData['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        allVerticalIds.addAll(items.map((item) => item['id'] as String));
      });

      // 4. Fetch all vertical xblocks (with one retry per failure).
      //    Also detects URL changes and marks stale downloads.
      await _parallelBounded(allVerticalIds, 4, (verticalId) async {
        await _fetchAndCacheXblock(client, db, verticalId, courseId: courseId, retry: true);
      });

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
    } on Object catch (e, st) {
      _log.warning('syncCourse($courseId): failed', e, st);
      final errorMsg = e.toString();
      await db.putSyncError(courseId, errorMsg);
      _updateCourseState(courseId, SyncStatus.error, errorMessage: errorMsg);
    }
  }

  Future<void> _fetchAndCacheXblock(
    dynamic client,
    dynamic db,
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
        await _fetchAndCacheXblock(client, db, verticalId, courseId: courseId, retry: false);
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
    dynamic db,
    String verticalId,
    List<ParsedVideoBlock> newVideos,
  ) async {
    final oldRow = await db.getXblock(verticalId);
    if (oldRow == null) return;

    XBlockContent oldContent;
    try {
      oldContent = XBlockContent.fromJson(
          jsonDecode(oldRow.data) as Map<String, dynamic>);
    } catch (_) {
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
    dynamic db,
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
      } catch (_) {}
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
        } catch (e) {
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

  /// Processes [items] in parallel, at most [concurrency] at a time.
  Future<void> _parallelBounded<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T) fn,
  ) async {
    for (var i = 0; i < items.length; i += concurrency) {
      final end = (i + concurrency).clamp(0, items.length);
      await Future.wait(
        items.sublist(i, end).map(fn),
        eagerError: false,
      );
    }
  }
}
