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
      failed: 0,
      stale: 0,
    );
    return;
  }

  yield* db.watchDownloadsForUrls(urls).map((rows) {
    var downloaded = 0;
    var downloading = 0;
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
