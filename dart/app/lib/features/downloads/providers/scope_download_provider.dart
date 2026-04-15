// ignore_for_file: uri_has_not_been_generated
import 'dart:convert';

import 'package:emajtee/core/storage/app_database.dart';
import 'package:emajtee/core/storage/database_provider.dart';
import 'package:emajtee/features/courses/models/outline.dart';
import 'package:emajtee/features/courses/models/sequence.dart';
import 'package:emajtee/features/courses/models/xblock_content.dart';
import 'package:emajtee/features/downloads/models/download_status.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'scope_download_provider.g.dart';

/// Watches the download state aggregated over a scope.
///
/// Supply [sequenceId] to scope to a sequence, [verticalId] to scope to a
/// single vertical (which also requires [sequenceId] for correctness but is
/// not enforced). Omit both to scope to the whole [courseId].
@riverpod
Stream<ScopeDownloadState> scopeDownloadState(
  Ref ref, {
  required String courseId,
  String? sequenceId,
  String? verticalId,
}) async* {
  final db = ref.read(appDatabaseProvider);

  final urls = await _collectUrls(
    db,
    courseId: courseId,
    sequenceId: sequenceId,
    verticalId: verticalId,
  );

  if (urls.isEmpty) {
    yield const ScopeDownloadState(
      total: 0,
      downloaded: 0,
      downloading: 0,
      pending: 0,
      failed: 0,
      stale: 0,
    );
    return;
  }

  yield* db.watchDownloadsForUrls(urls).map((rows) {
    var downloaded = 0;
    var downloading = 0;
    var pending = 0;
    var failed = 0;
    var stale = 0;
    for (final row in rows) {
      final s = DownloadStatus.fromName(row.status);
      switch (s) {
        case DownloadStatus.downloaded:
          downloaded++;
        case DownloadStatus.downloading:
        case DownloadStatus.queued:
          downloading++;
        case DownloadStatus.pending:
          pending++;
        case DownloadStatus.failed:
          failed++;
        case DownloadStatus.stale:
          stale++;
        case DownloadStatus.notDownloaded:
      }
    }
    return ScopeDownloadState(
      total: urls.length,
      downloaded: downloaded,
      downloading: downloading,
      pending: pending,
      failed: failed,
      stale: stale,
    );
  });
}

// ---------------------------------------------------------------------------
// Lecture-level aggregation (for the course overview progress bar)
// ---------------------------------------------------------------------------

/// Like [scopeDownloadState] but counts *lectures* (sequences) rather than
/// individual video clips. A lecture counts as "downloaded" only when every
/// clip inside it is downloaded.
///
/// Only sequences that contain at least one video are counted.
@riverpod
Stream<ScopeDownloadState> courseLectureDownloadState(
  Ref ref, {
  required String courseId,
}) async* {
  final db = ref.read(appDatabaseProvider);

  // Build sequence → urls map (preserving sequence order).
  final sequenceUrls = await _collectUrlsBySequence(db, courseId);

  if (sequenceUrls.isEmpty) {
    yield const ScopeDownloadState(
      total: 0,
      downloaded: 0,
      downloading: 0,
      pending: 0,
      failed: 0,
      stale: 0,
    );
    return;
  }

  // Flatten all URLs for the DB watch, keeping a reverse lookup.
  final allUrls = <String>[];
  final urlToSeqIndex = <String, int>{};
  for (var i = 0; i < sequenceUrls.length; i++) {
    for (final url in sequenceUrls[i]) {
      if (!urlToSeqIndex.containsKey(url)) {
        allUrls.add(url);
      }
      urlToSeqIndex[url] = i;
    }
  }

  yield* db.watchDownloadsForUrls(allUrls).map((rows) {
    // Build per-sequence status maps: seqIndex → set of statuses seen.
    final seqDownloaded = List.filled(sequenceUrls.length, 0);
    final seqTotal = sequenceUrls.map((u) => u.length).toList();

    final seqHasDownloading = List.filled(sequenceUrls.length, false);
    final seqHasPending = List.filled(sequenceUrls.length, false);
    final seqHasFailed = List.filled(sequenceUrls.length, false);
    final seqHasStale = List.filled(sequenceUrls.length, false);

    for (final row in rows) {
      final idx = urlToSeqIndex[row.url];
      if (idx == null) continue;
      final s = DownloadStatus.fromName(row.status);
      switch (s) {
        case DownloadStatus.downloaded:
          seqDownloaded[idx]++;
        case DownloadStatus.downloading:
        case DownloadStatus.queued:
          seqHasDownloading[idx] = true;
        case DownloadStatus.pending:
          seqHasPending[idx] = true;
        case DownloadStatus.failed:
          seqHasFailed[idx] = true;
        case DownloadStatus.stale:
          seqHasStale[idx] = true;
        case DownloadStatus.notDownloaded:
      }
    }

    // Aggregate across sequences.
    var downloaded = 0;
    var downloading = 0;
    var pending = 0;
    var failed = 0;
    var stale = 0;

    for (var i = 0; i < sequenceUrls.length; i++) {
      final total = seqTotal[i];
      if (total == 0) continue;
      if (seqDownloaded[i] == total) {
        downloaded++;
      } else if (seqHasDownloading[i]) {
        downloading++;
      } else if (seqHasPending[i]) {
        pending++;
      } else if (seqHasFailed[i]) {
        failed++;
      } else if (seqHasStale[i]) {
        stale++;
      }
    }

    return ScopeDownloadState(
      total: sequenceUrls.length,
      downloaded: downloaded,
      downloading: downloading,
      pending: pending,
      failed: failed,
      stale: stale,
    );
  });
}

// ---------------------------------------------------------------------------
// URL collection helpers
// ---------------------------------------------------------------------------

Future<List<String>> _collectUrls(
  AppDatabase db, {
  required String courseId,
  String? sequenceId,
  String? verticalId,
}) async {
  final urls = <String>{};

  if (verticalId != null) {
    await _addUrlsForVertical(db, verticalId, urls);
  } else if (sequenceId != null) {
    await _addUrlsForSequence(db, sequenceId, urls);
  } else {
    await _addUrlsForCourse(db, courseId, urls);
  }

  return urls.toList();
}

Future<void> _addUrlsForVertical(
  AppDatabase db,
  String verticalId,
  Set<String> out,
) async {
  final row = await db.getXblock(verticalId);
  if (row == null) return;
  final content =
      XBlockContent.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
  for (final v in content.videos) {
    if (v.mp4Url != null) out.add(v.mp4Url!);
  }
}

Future<void> _addUrlsForSequence(
  AppDatabase db,
  String sequenceId,
  Set<String> out,
) async {
  final row = await db.getSequence(sequenceId);
  if (row == null) return;
  final seq =
      SequenceDetail.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
  for (final item in seq.items) {
    await _addUrlsForVertical(db, item.id, out);
  }
}

Future<void> _addUrlsForCourse(
  AppDatabase db,
  String courseId,
  Set<String> out,
) async {
  final row = await db.getOutline(courseId);
  if (row == null) return;
  final outline =
      CourseOutline.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
  for (final section in outline.outline.sections) {
    for (final seqId in section.sequenceIds) {
      await _addUrlsForSequence(db, seqId, out);
    }
  }
}

/// Returns one list of URLs per sequence that has at least one video.
/// Sequences with no videos are omitted.
Future<List<List<String>>> _collectUrlsBySequence(
  AppDatabase db,
  String courseId,
) async {
  final row = await db.getOutline(courseId);
  if (row == null) return [];
  final outline =
      CourseOutline.fromJson(jsonDecode(row.data) as Map<String, dynamic>);

  final result = <List<String>>[];
  for (final section in outline.outline.sections) {
    for (final seqId in section.sequenceIds) {
      final urls = <String>{};
      await _addUrlsForSequence(db, seqId, urls);
      if (urls.isNotEmpty) result.add(urls.toList());
    }
  }
  return result;
}
