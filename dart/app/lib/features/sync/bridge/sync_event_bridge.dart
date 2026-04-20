import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_service.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';
import 'package:omnilect/features/courses/providers/enrollments_provider.dart';
import 'package:omnilect/features/courses/providers/ocw_courses_provider.dart';
import 'package:omnilect/features/courses/providers/outline_provider.dart';
import 'package:omnilect/features/courses/providers/sequence_provider.dart';
import 'package:omnilect/features/courses/providers/unsupported_courses_provider.dart';
import 'package:omnilect/features/courses/providers/xblock_provider.dart';
import 'package:omnilect/features/courses/utils/course_image_downloader.dart';
import 'package:omnilect/features/downloads/providers/video_download_manager.dart';
import 'package:omnilect/features/progress/providers/progress_tracker_provider.dart';
import 'package:omnilect/features/sync/isolate/isolate_logger_bridge.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/sync_manager.dart';
import 'package:omnilect/features/sync/providers/sync_providers.dart';

final _log = Logger('sync.bridge');

/// Fans out isolate-emitted [SyncEvent]s to the appropriate main-isolate
/// services:
///
/// - [AnalyticsEventForwarded] → `AnalyticsService`
/// - [RemovedVideoUrls] → `VideoDownloadManager.onRemovedVideoUrls`
/// - [PrefetchCourseImages] → `CourseImageDownloader.ensureDownloaded`
/// - [ValidateTrackedLecture] → `ProgressTracker.validateTrackedLecture`
/// - [DbInvalidated] → `ref.invalidate` of the matching provider family
/// - [LogRecordForwarded] → main-isolate `Logger('sync-isolate.<name>')`
class SyncEventBridge {
  SyncEventBridge({required this.syncManager, required this.ref}) {
    _sub = syncManager.events.listen(_dispatch);
  }

  final SyncManager syncManager;
  final Ref ref;
  late final StreamSubscription<SyncEvent> _sub;

  Future<void> dispose() => _sub.cancel();

  void _dispatch(SyncEvent event) {
    switch (event) {
      case LogRecordForwarded():
        applyForwardedLogRecord(event);
      case AnalyticsEventForwarded():
        _forwardAnalytics(event);
      case RemovedVideoUrls():
        unawaited(
          ref
              .read(videoDownloadManagerProvider)
              .onRemovedVideoUrls(event.urls, event.courseId),
        );
      case PrefetchCourseImages():
        _prefetchImages(event.urls);
      case ValidateTrackedLecture():
        unawaited(
          ref.read(progressTrackerProvider).validateTrackedLecture(event.courseId),
        );
      case DbInvalidated():
        _invalidate(event);
      case IsolateReady():
      case IsolateExited():
      case OpStarted():
      case OpCompleted():
      case OpCancelled():
      case OpErrored():
      case ScopeStateChanged():
      case SubtaskProgress():
      case SessionRefreshRequired():
        break;
    }
  }

  void _forwardAnalytics(AnalyticsEventForwarded event) {
    final analytics = ref.read(analyticsServiceProvider);
    final params = event.params;
    final scope = params[kParamScope] as String? ?? 'unknown';
    final courseId = params[kParamCourseId] as String?;
    final trigger = params[kParamTrigger] as String? ?? kTriggerAuto;
    final durationMs = params[kParamDurationMs] as int? ?? 0;
    final itemsSynced = params[kParamItemsSynced] as int? ?? 0;
    final stage = params[kParamStage] as String? ?? 'unknown';
    final errorKind = params[kParamErrorKind] as String? ?? 'unknown';

    switch (event.eventName) {
      case kEventSyncStart:
        unawaited(analytics.logSyncStart(
          scope: scope,
          trigger: trigger,
          courseId: courseId,
        ));
      case kEventSyncComplete:
        unawaited(analytics.logSyncComplete(
          scope: scope,
          durationMs: durationMs,
          itemsSynced: itemsSynced,
          courseId: courseId,
        ));
      case kEventSyncFailure:
        unawaited(analytics.logSyncFailure(
          scope: scope,
          durationMs: durationMs,
          stage: stage,
          errorKind: errorKind,
          courseId: courseId,
        ));
      default:
        _log.warning('unknown forwarded analytics event: ${event.eventName}');
    }
  }

  Future<void> _prefetchImages(List<String> urls) async {
    final downloader = ref.read(courseImageDownloaderProvider);
    // Kick off concurrently but bounded — the downloader itself dedup-caches,
    // so a small fan-out is fine.
    for (final url in urls) {
      if (url.isEmpty) continue;
      unawaited(downloader.ensureDownloaded(url));
    }
  }

  void _invalidate(DbInvalidated event) {
    final arg = event.arg;
    _log.info(
      'bridge: invalidate family=${event.family}${arg == null ? '' : '($arg)'}',
    );
    switch (event.family) {
      case 'enrollments':
        ref.invalidate(enrollmentsProvider);
      case 'memberships':
        // course_list_memberships drives both the home-screen enrolled and
        // OCW streams; invalidate both so Drift's watch() restarts against
        // a snapshot that sees the isolate's writes.
        ref
          ..invalidate(activeEnrollmentsProvider)
          ..invalidate(activeOcwCoursesProvider);
      case 'unsupported':
        ref.invalidate(unsupportedCoursesProvider);
      case 'availableLists':
        ref.invalidate(availableListsProvider);
      case 'courseOutline':
        if (arg != null) {
          ref.invalidate(courseOutlineProvider(courseId: arg));
        }
      case 'ocwCourse':
        if (arg != null) {
          ref.invalidate(ocwCourseProvider(arg));
        }
        // Home-screen OCW list reads `cached_ocw_courses` + memberships.
        // Memberships are written during reconciliation (and invalidate
        // activeOcwCoursesProvider via the 'memberships' branch above),
        // but the course rows themselves land here — one per OCW course
        // as `_fetchOcwCourse` completes. Without this invalidation, a
        // first-sync that added a new OCW course to the user's selection
        // leaves the home list showing 0 OCW tiles until the widget
        // remounts: the `memberships` invalidation fired before the rows
        // existed, and nothing re-queries after the rows land.
        ref.invalidate(activeOcwCoursesProvider);
      case 'sequenceDetail':
        if (arg != null) {
          ref.invalidate(sequenceDetailProvider(blockId: arg));
        }
      case 'xblockContent':
        if (arg != null) {
          ref.invalidate(xblockContentProvider(blockId: arg));
        }
      case 'courseSync':
        // Persisted per-course lastSyncedAt/lastError — UI reads this via
        // courseSyncRecordProvider (family keyed on courseId). With arg:
        // one course changed; without: a bulk refresh (e.g. post-sign-in).
        if (arg != null) {
          ref.invalidate(courseSyncRecordProvider(arg));
        } else {
          ref.invalidate(courseSyncRecordProvider);
        }
      case 'lectureSync':
        // Persisted per-lecture lastSyncedAt/lastError.
        if (arg != null) {
          ref.invalidate(lectureSyncRecordProvider(arg));
        } else {
          ref.invalidate(lectureSyncRecordProvider);
        }
      default:
        _log.warning('unknown DbInvalidated family: ${event.family}');
    }
  }
}
