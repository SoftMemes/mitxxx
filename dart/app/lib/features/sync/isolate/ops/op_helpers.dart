import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';
import 'package:omnilect/features/downloads/models/download_status.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

final _log = Logger('sync.ops');

/// Shared concurrency cap across all fetches inside a single logical op.
/// Matches the previous `kSyncConcurrency` in `sync_controller.dart`.
const int kSyncConcurrency = 16;

/// Translates a Dio 401/403 into [StaleSessionException] tagged with the
/// originating [SessionKind]. Other Dio errors rethrow as-is.
Never throwAsStaleOrRethrow(DioException e, SessionKind kind, [StackTrace? st]) {
  final status = e.response?.statusCode;
  if (status == 401 || status == 403) {
    throw StaleSessionException(kind, e);
  }
  if (st != null) {
    Error.throwWithStackTrace(e, st);
  }
  throw e;
}

bool isStaleStatus(Object e) {
  if (e is! DioException) return false;
  final s = e.response?.statusCode;
  return s == 401 || s == 403;
}

SessionKind kindForHost(Uri? uri) {
  if (uri == null) return SessionKind.mitxonline;
  final host = uri.host;
  if (host.contains('api.learn.mit.edu')) return SessionKind.learnApi;
  if (host.contains('courses.learn.mit.edu')) return SessionKind.lms;
  return SessionKind.mitxonline;
}

/// Eagerly refresh the api.learn.mit.edu session at the start of a logical
/// op that will call that host. Throws [StaleSessionException] with
/// [SessionKind.learnApi] on failure, which the manager's refresh chain
/// handles: silent WebView bootstrap first, escalation to the reauth dialog
/// if that also fails.
///
/// The userlists endpoint silently returns 200 with an empty result when
/// `session` is stale, so relying on 401/403 retries inside a sub-task is
/// not sufficient — we refresh up-front and bail if the fresh cookies don't
/// authenticate.
Future<void> ensureFreshLearnSession(OpRuntime r) async {
  final ok = await r.client.refreshLearnSession();
  if (!ok) {
    throw const StaleSessionException(SessionKind.learnApi);
  }
}

/// Build `If-None-Match` / `If-Modified-Since` conditional request headers.
Map<String, String>? conditionalHeaders({
  String? etag,
  String? lastModified,
}) {
  final headers = <String, String>{};
  if (etag != null) headers['If-None-Match'] = etag;
  if (lastModified != null) headers['If-Modified-Since'] = lastModified;
  return headers.isEmpty ? null : headers;
}

/// Parse an OCW course slug out of a learn.mit.edu `resource.runs[].slug`.
String? parseOcwSlug(String runSlug) {
  const prefix = 'courses/';
  if (!runSlug.startsWith(prefix)) return null;
  var s = runSlug.substring(prefix.length);
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.contains('/') || s.isEmpty) return null;
  return s;
}

// ---------------------------------------------------------------------------
// Enrollment fetch
// ---------------------------------------------------------------------------

/// Fetches enrollments from mitxonline v1, persists the JSON, returns parsed
/// list. Throws [StaleSessionException] on 401/403.
///
/// Uses v1 on mitxonline (not the learn.mit.edu v3 proxy) because v3 strips
/// `run.course` down to a handful of ids — no `feature_image_src`,
/// `description`, or `page_url` — which would force a secondary lookup per
/// course just to render the home screen tiles.
Future<List<Enrollment>> fetchEnrollments(OpRuntime r) async {
  _log.info('fetchEnrollments: GET /api/v1/enrollments/');
  try {
    final response = await r.client.mitxOnline.get<dynamic>(
      '/api/v1/enrollments/',
      cancelToken: r.token,
    );
    final list = response.data as List<dynamic>;
    await r.db.putEnrollments(jsonEncode(list));
    final parsed = list
        .map((e) => Enrollment.fromJson(e as Map<String, dynamic>))
        .toList();
    _log.info('fetchEnrollments: ${parsed.length} enrollment(s)');
    return parsed;
  } on DioException catch (e, st) {
    _log.warning(
      'fetchEnrollments: DioException status=${e.response?.statusCode}',
      e,
    );
    throwAsStaleOrRethrow(e, SessionKind.mitxonline, st);
  }
}

// ---------------------------------------------------------------------------
// List reconciliation
// ---------------------------------------------------------------------------

class ListReconcileResult {
  ListReconcileResult({
    required this.courseIds,
    required this.unsupported,
  });
  final Set<String> courseIds;
  final List<UnsupportedListItemsCompanion> unsupported;
}

/// Reconciles memberships across all selected lists. Writes
/// `course_list_memberships` and `unsupported_list_items`. Returns the union
/// of supported course ids across selected lists (intersected with
/// enrollments for MITx content). On a learnApi 401/403, throws
/// [StaleSessionException].
Future<Set<String>> reconcileMembership(
  OpRuntime r,
  List<Enrollment> enrollments,
) async {
  final selection = await r.db.getSelectedLists();
  _log.info(
    'reconcile: ${selection.length} selected list(s): '
    '${selection.map((s) => '${s.listId}(${s.source})').toList()}',
  );
  if (selection.isEmpty) {
    _log.warning('reconcile: no selected lists — returning empty target set');
    return const <String>{};
  }

  final enrolledIds = {for (final e in enrollments) e.run.coursewareId};
  _log.info('reconcile: ${enrolledIds.length} enrolled courseware id(s)');
  final target = <String>{};

  for (final selected in selection) {
    if (r.token.isCancelled) break;
    final source = ListSource.fromStorage(selected.source);
    final listId = selected.listId;
    ListReconcileResult? listResult;
    try {
      listResult = await _fetchListCourseIds(
        r: r,
        listId: listId,
        source: source,
        enrolledIds: enrolledIds,
      );
    } on DioException catch (e) {
      if (isStaleStatus(e)) {
        throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
      }
      _log.warning('reconcile: list $listId fetch failed', e);
    } on StaleSessionException {
      rethrow;
    } on Object catch (e, st) {
      _log.warning('reconcile: list $listId fetch failed', e, st);
    }

    if (listResult != null) {
      _log.info(
        'reconcile: list $listId → ${listResult.courseIds.length} supported, '
        '${listResult.unsupported.length} unsupported',
      );
      await r.db.rebuildMembershipForList(listId, listResult.courseIds);
      await r.db.rebuildUnsupportedForList(listId, listResult.unsupported);
      target.addAll(listResult.courseIds);
    } else {
      // Preserve prior union when this list failed to fetch.
      final existing = await (r.db.select(r.db.courseListMemberships)
            ..where((t) => t.listId.equals(listId)))
          .get();
      _log.info(
        'reconcile: list $listId fetch failed — preserving '
        '${existing.length} existing membership(s)',
      );
      target.addAll(existing.map((m) => m.courseId));
    }
  }

  // Drop-cascade: courses not in any selection.
  final drops = await r.db.getCoursesNotInSelection();
  if (drops.isNotEmpty) {
    _log.info('reconcile: dropping ${drops.length} course(s): $drops');
    for (final courseId in drops) {
      // Collect removed video URLs before wiping cache.
      final existingDownloads = await r.db.getDownloadsForCourse(courseId);
      final removedUrls = existingDownloads.map((d) => d.url).toList();
      await r.db.deleteCourseCache(courseId);
      if (removedUrls.isNotEmpty) {
        r.events.add(RemovedVideoUrls(removedUrls, courseId));
      }
    }
  }

  _log.info(
    'reconcile: wrote memberships; target union = ${target.length} course(s)',
  );

  // Cross-isolate: main-isolate Drift `watch()` streams don't fire for
  // writes committed on this isolate. Emit one event per table the home
  // screen depends on so the bridge can imperatively invalidate the
  // matching stream providers.
  r.events.add(const DbInvalidated('memberships'));
  r.events.add(const DbInvalidated('unsupported'));

  return target;
}

Future<ListReconcileResult> _fetchListCourseIds({
  required OpRuntime r,
  required String listId,
  required ListSource source,
  required Set<String> enrolledIds,
}) async {
  switch (source) {
    case ListSource.enrolled:
      return ListReconcileResult(
        courseIds: enrolledIds,
        unsupported: const [],
      );
    case ListSource.learnMyList:
      final resp = await r.client.learnApi.get<dynamic>(
        '/api/v1/userlists/$listId/items/',
        queryParameters: {'limit': 1000},
        cancelToken: r.token,
      );
      final body = resp.data as Map<String, dynamic>;
      final results = (body['results'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final supported = <String>{};
      final unsupported = <UnsupportedListItemsCompanion>[];
      for (final item in results) {
        final resource = item['resource'] as Map<String, dynamic>? ?? {};
        final platform = resource['platform'] as Map<String, dynamic>? ?? {};
        final platformCode = platform['code'] as String? ?? 'unknown';
        final readableId = resource['readable_id'] as String? ?? '';
        final title = resource['title'] as String? ?? readableId;

        if (platformCode == 'mitxonline') {
          final runs = (resource['runs'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          for (final run in runs) {
            final courseId = run['courseware_id'] as String?;
            if (courseId != null && enrolledIds.contains(courseId)) {
              supported.add(courseId);
            }
          }
        } else if (platformCode == 'ocw') {
          final runs = (resource['runs'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          String? ocwSlug;
          for (final run in runs) {
            final runSlug = run['slug'] as String?;
            if (runSlug == null) continue;
            final parsed = parseOcwSlug(runSlug);
            if (parsed != null) {
              ocwSlug = parsed;
              break;
            }
          }
          if (ocwSlug != null) {
            supported.add('ocw:$ocwSlug');
          } else if (readableId.isNotEmpty) {
            unsupported.add(
              UnsupportedListItemsCompanion.insert(
                courseId: readableId,
                listId: listId,
                title: title,
                platformCode: platformCode,
              ),
            );
          }
        } else if (readableId.isNotEmpty) {
          unsupported.add(
            UnsupportedListItemsCompanion.insert(
              courseId: readableId,
              listId: listId,
              title: title,
              platformCode: platformCode,
            ),
          );
        }
      }
      return ListReconcileResult(
        courseIds: supported,
        unsupported: unsupported,
      );
  }
}

// ---------------------------------------------------------------------------
// Outline fetch (MITx + OCW dispatch)
// ---------------------------------------------------------------------------

/// Fetches + persists the course outline and returns sequence ids in course
/// order. OCW branches to end-to-end fetch and returns an empty list (no
/// sequences to schedule).
Future<List<String>> fetchOutline(OpRuntime r, String courseId) async {
  _log.info('fetchOutline: $courseId');
  if (courseId.startsWith('ocw:')) {
    return _fetchOcwCourse(r, courseId);
  }

  final cachedOutline = await r.db.getOutline(courseId);
  final outlineHeaders = conditionalHeaders(
    etag: cachedOutline?.etag,
    lastModified: cachedOutline?.lastModified,
  );
  Map<String, dynamic> outlineData;
  try {
    final outlineResp = await r.client.lms.get<dynamic>(
      '/api/learning_sequences/v1/course_outline/$courseId',
      options: outlineHeaders != null ? Options(headers: outlineHeaders) : null,
      cancelToken: r.token,
    );
    outlineData = outlineResp.data as Map<String, dynamic>;
    final outlineSection = outlineData['outline'] as Map<String, dynamic>?;
    if ((outlineSection?['sections'] as List? ?? []).isNotEmpty) {
      await r.db.putOutline(
        courseId,
        jsonEncode(outlineData),
        etag: outlineResp.headers.value('etag'),
        lastModified: outlineResp.headers.value('last-modified'),
      );
    }
  } on DioException catch (e, st) {
    if (e.response?.statusCode == 304 && cachedOutline != null) {
      _log.info('fetchOutline: $courseId 304 (using cached)');
      outlineData = jsonDecode(cachedOutline.data) as Map<String, dynamic>;
    } else if (isStaleStatus(e)) {
      _log.warning(
        'fetchOutline: $courseId stale-session status=${e.response?.statusCode}',
      );
      throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
    } else {
      _log.warning(
        'fetchOutline: $courseId failed status=${e.response?.statusCode}',
        e,
      );
      Error.throwWithStackTrace(e, st);
    }
  }
  final outlineSection = outlineData['outline'] as Map<String, dynamic>?;
  final sections =
      (outlineSection?['sections'] as List? ?? []).cast<dynamic>();
  final seqIds = sections
      .expand<String>(
        (s) => ((s as Map<String, dynamic>)['sequence_ids'] as List? ?? [])
            .cast<String>(),
      )
      .toList();
  _log.info(
    'fetchOutline: $courseId → ${sections.length} section(s), '
    '${seqIds.length} sequence(s)',
  );
  return seqIds;
}

Future<List<String>> _fetchOcwCourse(OpRuntime r, String courseId) async {
  final slug = courseId.substring('ocw:'.length);
  // Snapshot existing mp4 URLs so we can compute the drop set afterwards.
  final oldMp4s = (await r.db.getOcwLectureMp4Urls(courseId)).toSet();

  final course = await r.ocwFetcher.fetchCourse(courseId: courseId, slug: slug);

  final allLectures = [
    for (final s in course.sections) ...s.lectures,
  ];
  final allResources = <OcwResource>[
    for (final s in course.sections)
      for (final l in s.lectures) ...l.resources,
    ...course.orphanResources,
  ];

  await r.db.replaceOcwCourse(
    course: CachedOcwCoursesCompanion.insert(
      courseId: course.id,
      slug: course.slug,
      title: course.title,
      courseNumber: course.courseNumber,
      description: course.description,
      imageUrl: Value(course.imageUrl),
      cachedAt: DateTime.now(),
    ),
    lectures: [
      for (final l in allLectures)
        CachedOcwLecturesCompanion.insert(
          lectureId: l.id,
          courseId: course.id,
          slug: l.slug,
          title: l.title,
          sectionTitle: l.sectionTitle,
          sectionOrder: l.sectionOrder,
          lectureOrder: l.lectureOrder,
          mp4Url: Value(l.mp4Url),
          durationSeconds: Value(l.durationSeconds),
          cachedAt: DateTime.now(),
        ),
    ],
    resources: [
      for (final res in allResources)
        CachedOcwResourcesCompanion.insert(
          resourceId: res.id,
          courseId: course.id,
          lectureId: Value(res.lectureId),
          type: res.type.name,
          title: res.title,
          url: res.url,
          cachedAt: DateTime.now(),
        ),
    ],
  );

  // Drop removed MP4s.
  final newMp4s = <String>{
    for (final l in allLectures)
      if (l.mp4Url != null) l.mp4Url!,
  };
  final removed = <String>[];
  for (final oldUrl in oldMp4s.difference(newMp4s)) {
    final path = await r.db.removeCourseFromDownload(oldUrl, courseId);
    if (path != null && path.isNotEmpty) {
      try {
        File(path).deleteSync();
        _log.info('Deleted orphaned OCW download: $path');
      } on Object catch (e) {
        _log.warning('Could not delete orphaned file $path: $e');
      }
    }
    removed.add(oldUrl);
  }
  if (removed.isNotEmpty) {
    r.events.add(RemovedVideoUrls(removed, courseId));
  }

  // Let UI refresh. `ocwCourse` targets the single-course stream provider
  // (ocwCourseProvider family) that the course-outline screen watches;
  // `courseOutline` targets the legacy Future-backed provider. Both are
  // needed because independent callers watch each.
  r.events.add(DbInvalidated('courseOutline', courseId));
  r.events.add(DbInvalidated('ocwCourse', courseId));
  // Prefetch image on main side (needs path_provider).
  if (course.imageUrl != null && course.imageUrl!.isNotEmpty) {
    r.events.add(PrefetchCourseImages([course.imageUrl!]));
  }

  return const [];
}

// ---------------------------------------------------------------------------
// Sequence + xblock fetching
// ---------------------------------------------------------------------------

/// Returns the list of vertical ids inside [sequenceId]. Writes the cache.
Future<List<String>> fetchSequenceMetadata(
  OpRuntime r,
  String sequenceId,
) async {
  final cachedSeq = await r.db.getSequence(sequenceId);
  final seqHeaders = conditionalHeaders(
    etag: cachedSeq?.etag,
    lastModified: cachedSeq?.lastModified,
  );
  Map<String, dynamic> seqData;
  try {
    final seqResp = await r.client.lms.get<dynamic>(
      '/api/courseware/sequence/$sequenceId',
      options: seqHeaders != null ? Options(headers: seqHeaders) : null,
      cancelToken: r.token,
    );
    seqData = seqResp.data as Map<String, dynamic>;
    await r.db.putSequence(
      sequenceId,
      jsonEncode(seqData),
      etag: seqResp.headers.value('etag'),
      lastModified: seqResp.headers.value('last-modified'),
    );
  } on DioException catch (e, st) {
    if (e.response?.statusCode == 304 && cachedSeq != null) {
      seqData = jsonDecode(cachedSeq.data) as Map<String, dynamic>;
    } else if (isStaleStatus(e)) {
      throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
    } else {
      Error.throwWithStackTrace(e, st);
    }
  }
  final items =
      ((seqData['items'] as List?) ?? []).cast<Map<String, dynamic>>();
  r.events.add(DbInvalidated('sequenceDetail', sequenceId));
  return items.map((item) => item['id'] as String).toList();
}

Future<void> fetchAndCacheXblock(
  OpRuntime r,
  String verticalId, {
  required String courseId,
  bool retry = true,
}) async {
  try {
    final cachedXblock = await r.db.getXblock(verticalId);
    final xblockHeaders = conditionalHeaders(
      etag: cachedXblock?.etag,
      lastModified: cachedXblock?.lastModified,
    );
    final Response<dynamic> resp;
    try {
      resp = await r.client.lms.get<dynamic>(
        '/xblock/$verticalId',
        options: xblockHeaders != null ? Options(headers: xblockHeaders) : null,
        cancelToken: r.token,
      );
    } on DioException catch (e, st) {
      if (e.response?.statusCode == 304) return;
      if (isStaleStatus(e)) {
        throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
      }
      Error.throwWithStackTrace(e, st);
    }
    final html =
        resp.data is String ? resp.data as String : resp.data.toString();
    final videos = extractVideoMetadata(html);
    final content = XBlockContent(
      videos: videos,
      htmlContent: html,
      hasContent: html.trim().isNotEmpty,
    );
    try {
      await _detectStaleDownloads(r, verticalId, videos);
    } on Object catch (e, st) {
      _log.warning('stale-download detection failed for $verticalId', e, st);
    }
    await r.db.putXblock(
      verticalId,
      jsonEncode(content.toJson()),
      etag: resp.headers.value('etag'),
      lastModified: resp.headers.value('last-modified'),
    );
    try {
      await r.db.putSanitizedXblock(
        blockId: verticalId,
        safeHtml: sanitizeXBlockHtml(html),
        sanitizerVersion: kSanitizerVersion,
      );
    } on Object catch (e, st) {
      _log.warning('sanitized-html cache warmup failed for $verticalId', e, st);
    }
    r.events.add(DbInvalidated('xblockContent', verticalId));
  } on StaleSessionException {
    rethrow;
  } on Object catch (e, st) {
    if (retry && !r.token.isCancelled) {
      _log.warning('xblock $verticalId failed, retrying', e, st);
      await fetchAndCacheXblock(r, verticalId, courseId: courseId, retry: false);
    } else {
      _log.warning('xblock $verticalId failed after retry', e, st);
      Error.throwWithStackTrace(e, st);
    }
  }
}

Future<void> _detectStaleDownloads(
  OpRuntime r,
  String verticalId,
  List<ParsedVideoBlock> newVideos,
) async {
  final oldRow = await r.db.getXblock(verticalId);
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
    final downloaded = await r.db.getDownloadedVideo(oldUrl);
    if (downloaded != null &&
        downloaded.status == DownloadStatus.downloaded.name) {
      await r.db.markDownloadStale(oldUrl);
      _log.info('Marked stale: $oldUrl (vertical $verticalId)');
    }
  }
}

// ---------------------------------------------------------------------------
// Post-course-sync cleanup of removed video URLs
// ---------------------------------------------------------------------------

/// Computes which video URLs were removed by this sync pass (compared to
/// the prior cached structure) and emits a [RemovedVideoUrls] event. Also
/// deletes any fully-orphaned local files. Mirrors the logic previously in
/// `SyncController._cleanupRemovedVideos`.
Future<void> cleanupRemovedVideos(
  OpRuntime r,
  String courseId,
  List<String> currentVerticalIds,
) async {
  final currentUrls = <String>{};
  for (final vertId in currentVerticalIds) {
    final row = await r.db.getXblock(vertId);
    if (row == null) continue;
    try {
      final content = XBlockContent.fromJson(
          jsonDecode(row.data) as Map<String, dynamic>);
      for (final v in content.videos) {
        if (v.mp4Url != null) currentUrls.add(v.mp4Url!);
      }
    } on Object catch (_) {}
  }

  final courseDownloads = await r.db.getDownloadsForCourse(courseId);
  final removed = <String>[];
  for (final row in courseDownloads) {
    if (currentUrls.contains(row.url)) continue;
    removed.add(row.url);
    final orphanedPath =
        await r.db.removeCourseFromDownload(row.url, courseId);
    if (orphanedPath != null && orphanedPath.isNotEmpty) {
      try {
        File(orphanedPath).deleteSync();
        _log.info('Deleted orphaned download: $orphanedPath');
      } on Object catch (e) {
        _log.warning('Could not delete orphaned file $orphanedPath: $e');
      }
    }
  }
  if (removed.isNotEmpty) {
    r.events.add(RemovedVideoUrls(removed, courseId));
  }
}
