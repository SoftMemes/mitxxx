// ignore_for_file: uri_has_not_been_generated
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:omnilect/features/courses/models/sequence.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/downloads/models/download_status.dart';
import 'package:omnilect/features/downloads/utils/download_paths.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'video_download_manager.g.dart';

final _log = Logger('downloads');

const _kGroup = 'videos';
const _kConcurrency = 3;

@Riverpod(keepAlive: true)
VideoDownloadManager videoDownloadManager(Ref ref) {
  final db = ref.read(appDatabaseProvider);
  final manager = VideoDownloadManager._(db, ref);
  ref.onDispose(manager._dispose);
  return manager;
}

/// Tracks the aggregate state of a scoped download job for analytics.
class _DownloadJob {
  _DownloadJob({
    required this.scope,
    required this.courseId,
    required this.videoCount,
    required this.startedAt,
    this.blockId,
  });

  final String scope;
  final String courseId;
  final String? blockId;
  final int videoCount;
  final DateTime startedAt;
  int completed = 0;
  int bytesDownloaded = 0;
}

/// Service that manages video downloads using background_downloader.
///
/// All persistent state lives in [AppDatabase.downloadedVideos]. This class
/// orchestrates the download engine and keeps the DB in sync with task events.
class VideoDownloadManager {
  VideoDownloadManager._(this._db, this._ref) {
    _init();
  }

  final AppDatabase _db;
  final Ref _ref;

  /// Active download jobs keyed by a scope identifier (url of first video or
  /// blockId/courseId combo). Used for aggregate completion analytics.
  final Map<String, _DownloadJob> _jobs = {};

  Future<void> _init() async {
    await FileDownloader().configure(globalConfig: [
      (Config.holdingQueue, (_kConcurrency, null, null)),
    ]);

    FileDownloader().updates.listen(_handleUpdate);

    // Re-queue any rows left in 'pending' or 'queued' state from a previous
    // session (app was killed before background_downloader could pick them up).
    final all = await _db.getAllDownloadedVideos();
    for (final row in all) {
      if (row.status == DownloadStatus.pending.name ||
          row.status == DownloadStatus.queued.name) {
        await _enqueueTask(row.url);
      }
    }
  }

  void _dispose() {
    FileDownloader().destroy();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Enqueues downloads for all videos in the given scope.
  /// Already-downloaded URLs are skipped (dedup by URL).
  Future<void> enqueueScope({
    required String courseId,
    String? sequenceId,
    String? verticalId,
  }) async {
    final urls = await _collectUrls(
      courseId: courseId,
      sequenceId: sequenceId,
      verticalId: verticalId,
    );

    final scope = verticalId != null
        ? kScopeVideo
        : sequenceId != null
            ? kScopeSection
            : kScopeCourse;
    final blockId = verticalId ?? sequenceId;

    final urlsToDownload = <String>[];
    for (final url in urls) {
      final existing = await _db.getDownloadedVideo(url);
      if (existing != null &&
          (existing.status == DownloadStatus.downloaded.name ||
              existing.status == DownloadStatus.downloading.name ||
              existing.status == DownloadStatus.queued.name ||
              existing.status == DownloadStatus.pending.name)) {
        // Already downloaded or in-flight — skip.
        continue;
      }
      urlsToDownload.add(url);
    }

    if (urlsToDownload.isEmpty) return;

    // Register job for aggregate analytics.
    final jobKey = blockId ?? courseId;
    _jobs[jobKey] = _DownloadJob(
      scope: scope,
      courseId: courseId,
      videoCount: urlsToDownload.length,
      startedAt: DateTime.now(),
      blockId: blockId,
    );

    unawaited(_ref.read(analyticsServiceProvider).logDownloadStart(
      scope: scope,
      courseId: courseId,
      videoCount: urlsToDownload.length,
      blockId: blockId,
    ));

    for (final url in urlsToDownload) {
      // If stale or failed, re-download.
      final localPath = await localPathForUrl(url);
      final courseIds = await _mergedCourseIds(url, courseId);

      // Write 'pending' first so the UI shows the hourglass immediately,
      // then transition to 'queued' after handing off to background_downloader.
      await _db.upsertDownloadedVideo(DownloadedVideosCompanion.insert(
        url: url,
        localFilePath: localPath,
        courseIds: jsonEncode(courseIds),
        status: DownloadStatus.pending.name,
        taskId: Value(urlToSha1(url)),
        updatedAt: DateTime.now(),
      ));

      await _enqueueTask(url);
    }
  }

  /// Cancels an active download for [url] and removes it from the DB.
  Future<void> cancel(String url) async {
    final taskId = urlToSha1(url);
    await FileDownloader().cancelTasksWithIds([taskId]);
    await _db.deleteDownloadedVideo(url);
  }

  /// Deletes downloaded video(s) for the given scope.
  /// Removes the [courseId] reference from each URL; deletes the file + row if
  /// no other course references it.
  Future<void> deleteScope({
    required String courseId,
    String? sequenceId,
    String? verticalId,
  }) async {
    final urls = await _collectUrls(
      courseId: courseId,
      sequenceId: sequenceId,
      verticalId: verticalId,
    );

    for (final url in urls) {
      final localFilePath = await _db.removeCourseFromDownload(url, courseId);
      if (localFilePath != null && localFilePath.isNotEmpty) {
        try {
          File(localFilePath).deleteSync();
        } on Object catch (e) {
          _log.warning('Could not delete file $localFilePath: $e');
        }
      }
    }
  }

  /// Cancels every active/queued background download task. DB rows and files
  /// are left intact — callers that want to wipe those should call the
  /// corresponding DB/file delete paths themselves. Pair this with a DB wipe
  /// when the user asks to delete videos or all data, so a task completing
  /// mid-wipe can't resurrect a row or write a file to disk.
  Future<void> cancelAllTasks() async {
    final all = await _db.getAllDownloadedVideos();
    final taskIds = all.map((r) => r.taskId).whereType<String>().toList();
    if (taskIds.isNotEmpty) {
      await FileDownloader().cancelTasksWithIds(taskIds);
    }
    _jobs.clear();
  }

  /// Deletes all downloaded files and their DB rows.
  /// Called during sign-out (the auth provider calls db.clearAll separately).
  Future<void> deleteAllFiles() async {
    final all = await _db.getAllDownloadedVideos();
    final taskIds = all.map((r) => r.taskId).whereType<String>().toList();
    if (taskIds.isNotEmpty) {
      await FileDownloader().cancelTasksWithIds(taskIds);
    }
    for (final row in all) {
      if (row.localFilePath.isNotEmpty) {
        try {
          File(row.localFilePath).deleteSync();
        } on Object catch (_) {}
      }
    }
    // DB rows are cleared by db.clearAll() in the auth provider.
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _enqueueTask(String url) async {
    final sha1hex = urlToSha1(url);
    final task = DownloadTask(
      taskId: sha1hex,
      url: url,
      filename: '$sha1hex.mp4',
      directory: 'downloads',
      baseDirectory: BaseDirectory.applicationSupport,
      group: _kGroup,
      retries: 3,
      allowPause: true,
      metaData: url, // store original URL so we can look up the DB row
    );
    await FileDownloader().enqueue(task);
    // Transition from 'pending' → 'queued' now that the task is in the
    // background_downloader holding queue.
    await _db.markDownloadQueued(url);
    _log.fine('Enqueued download for $url');
  }

  void _handleUpdate(TaskUpdate update) {
    switch (update) {
      case TaskStatusUpdate(:final task, :final status):
        _handleStatus(task, status);
      case TaskProgressUpdate(:final task, :final progress, :final expectedFileSize):
        _handleProgress(task, progress, expectedFileSize);
    }
  }

  Future<void> _handleStatus(Task task, TaskStatus status) async {
    final url = task.metaData;
    if (url.isEmpty) return;

    switch (status) {
      case TaskStatus.complete:
        final localPath = await localPathForUrl(url);
        await _db.markDownloadComplete(url, localPath);
        _log.fine('Download complete: $url → $localPath');
        _onVideoComplete(url);

      case TaskStatus.failed:
        await _db.markDownloadFailed(url);
        _log.warning('Download failed: $url');
        _onVideoFailed(url, 'network');

      case TaskStatus.canceled:
        // cancel() already removes the row; nothing to do here.
        _onVideoFailed(url, 'cancelled');

      case TaskStatus.running:
        // Progress callbacks will flip status to 'downloading' via
        // updateDownloadProgress; nothing extra needed here.

      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
      case TaskStatus.paused:
      case TaskStatus.notFound:
    }
  }

  void _onVideoComplete(String url) {
    _advanceJobs(url, completed: true, bytes: 0);
  }

  void _onVideoFailed(String url, String errorKind) {
    _advanceJobs(url, completed: false, bytes: 0, errorKind: errorKind);
  }

  void _advanceJobs(String url, {
    required bool completed,
    required int bytes,
    String? errorKind,  // ignore: always_put_required_named_parameters_first
  }) {
    final analytics = _ref.read(analyticsServiceProvider);
    final toRemove = <String>[];

    for (final entry in _jobs.entries) {
      final job = entry.value;
      if (completed) {
        job.completed++;
        job.bytesDownloaded += bytes;
      }

      final remaining = job.videoCount - job.completed;
      if (remaining <= 0 || (!completed && errorKind != null)) {
        final durationMs =
            DateTime.now().difference(job.startedAt).inMilliseconds;
        if (completed) {
          unawaited(analytics.logDownloadComplete(
            scope: job.scope,
            courseId: job.courseId,
            durationMs: durationMs,
            bytesDownloaded: job.bytesDownloaded,
            videoCount: job.completed,
            blockId: job.blockId,
          ));
        } else {
          unawaited(analytics.logDownloadFailure(
            scope: job.scope,
            courseId: job.courseId,
            errorKind: errorKind ?? 'unknown',
            videosCompleted: job.completed,
            videosTotal: job.videoCount,
            blockId: job.blockId,
          ));
        }
        toRemove.add(entry.key);
      }
    }

    for (final key in toRemove) {
      _jobs.remove(key);
    }
  }

  Future<void> _handleProgress(
    Task task,
    double progress,
    int expectedFileSize,
  ) async {
    final url = task.metaData;
    if (url.isEmpty || progress < 0) return; // -1 = indeterminate

    final bytesDownloaded =
        expectedFileSize > 0 ? (progress * expectedFileSize).round() : 0;

    await _db.updateDownloadProgress(
      url,
      progress: progress,
      bytesDownloaded: bytesDownloaded,
      totalBytes: expectedFileSize,
    );

    // When progress reaches 1.0 update the job's byte tally so
    // logDownloadComplete carries an accurate total.
    if (progress >= 1.0 && bytesDownloaded > 0) {
      for (final job in _jobs.values) {
        job.bytesDownloaded += bytesDownloaded;
      }
    }
  }

  Future<List<String>> _collectUrls({
    required String courseId,
    String? sequenceId,
    String? verticalId,
  }) async {
    final urls = <String>{};

    if (verticalId != null) {
      await _addUrlsForVertical(verticalId, urls);
    } else if (sequenceId != null) {
      await _addUrlsForSequence(sequenceId, urls);
    } else {
      await _addUrlsForCourse(courseId, urls);
    }

    return urls.toList();
  }

  Future<void> _addUrlsForVertical(String verticalId, Set<String> out) async {
    final row = await _db.getXblock(verticalId);
    if (row == null) return;
    final content =
        XBlockContent.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
    for (final v in content.videos) {
      if (v.mp4Url != null) out.add(v.mp4Url!);
    }
  }

  Future<void> _addUrlsForSequence(String sequenceId, Set<String> out) async {
    final row = await _db.getSequence(sequenceId);
    if (row == null) return;
    final seq =
        SequenceDetail.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
    for (final item in seq.items) {
      await _addUrlsForVertical(item.id, out);
    }
  }

  Future<void> _addUrlsForCourse(String courseId, Set<String> out) async {
    final row = await _db.getOutline(courseId);
    if (row == null) return;
    final outline =
        CourseOutline.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
    for (final section in outline.outline.sections) {
      for (final seqId in section.sequenceIds) {
        await _addUrlsForSequence(seqId, out);
      }
    }
  }

  /// Returns the merged courseIds list for [url], including [courseId].
  Future<List<String>> _mergedCourseIds(String url, String courseId) async {
    final existing = await _db.getDownloadedVideo(url);
    final current = existing != null
        ? (jsonDecode(existing.courseIds) as List<dynamic>).cast<String>()
        : <String>[];
    return {...current, courseId}.toList();
  }
}
