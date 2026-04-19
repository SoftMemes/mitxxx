import 'dart:async';

import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// Isolate-side analytics facade. Emits [AnalyticsEventForwarded] events
/// which the main-isolate bridge routes to the existing `AnalyticsService`.
///
/// Keeps the same event-name / param-key schema as `AnalyticsService` so
/// the main-side dispatcher can translate each event type cleanly.
class IsolateAnalytics {
  IsolateAnalytics(this._events);

  final EventSink<SyncEvent> _events;

  void logSyncStart({
    required String scope,
    String? courseId,
    String? blockId,
    String trigger = kTriggerManual,
  }) {
    _events.add(AnalyticsEventForwarded(kEventSyncStart, {
      kParamScope: scope,
      if (courseId != null) kParamCourseId: courseId,
      if (blockId != null) kParamBlockId: blockId,
      kParamTrigger: trigger,
    }));
  }

  void logSyncComplete({
    required String scope,
    required int durationMs, String? courseId,
    String? blockId,
    int itemsSynced = 0,
  }) {
    _events.add(AnalyticsEventForwarded(kEventSyncComplete, {
      kParamScope: scope,
      if (courseId != null) kParamCourseId: courseId,
      if (blockId != null) kParamBlockId: blockId,
      kParamDurationMs: durationMs,
      kParamItemsSynced: itemsSynced,
    }));
  }

  void logSyncFailure({
    required String scope,
    required int durationMs, required String stage, required String errorKind, String? courseId,
    String? blockId,
  }) {
    _events.add(AnalyticsEventForwarded(kEventSyncFailure, {
      kParamScope: scope,
      if (courseId != null) kParamCourseId: courseId,
      if (blockId != null) kParamBlockId: blockId,
      kParamDurationMs: durationMs,
      kParamStage: stage,
      kParamErrorKind: errorKind,
    }));
  }
}
