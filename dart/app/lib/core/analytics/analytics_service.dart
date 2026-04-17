// ignore_for_file: uri_has_not_been_generated
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/core/analytics/analytics_preferences.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'analytics_service.g.dart';

final _analyticsLog = Logger('analytics');

/// Central analytics service. All Firebase Analytics calls route through here.
///
/// Instantiated as a Riverpod provider so it can react to the user's opt-in
/// preference. When opted out, all log methods no-op and Firebase
/// collection is disabled.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  final optedIn = ref.watch(analyticsPreferencesProvider).value ?? true;
  // Sync the Firebase SDK's collection state whenever the preference changes.
  FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(optedIn);
  return AnalyticsService._(optedIn: optedIn);
}

class AnalyticsService {
  AnalyticsService._({required this.optedIn});

  final bool optedIn;
  final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  // ---------------------------------------------------------------------------
  // FirebaseAnalyticsObserver for GoRouter
  // ---------------------------------------------------------------------------

  FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _analytics);

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _emit(String name, [Map<String, Object?>? params]) async {
    if (!optedIn) return;
    if (kDebugMode) {
      _analyticsLog.info('[$name] ${params ?? {}}');
    }
    // Firebase logEvent only accepts String or num values; convert bools to int.
    final normalized = params?.map(
      (k, v) => MapEntry(k, v is bool ? (v ? 1 : 0) : v),
    );
    await _analytics.logEvent(name: name, parameters: normalized?.cast());
  }

  // ---------------------------------------------------------------------------
  // App-level events
  // ---------------------------------------------------------------------------

  Future<void> logAppOpen({required bool isFirstOpen}) => _emit(kEventAppOpen, {
        kParamPlatform: Platform.isIOS ? 'ios' : 'android',
        kParamIsFirstOpen: isFirstOpen,
      });

  Future<void> logLoginSuccess() =>
      _emit(kEventLoginSuccess, {kParamMethod: 'keycloak_sso'});

  Future<void> logLoginFailure({
    required String reason,
    required String stage,
  }) =>
      _emit(kEventLoginFailure, {kParamReason: reason, kParamStage: stage});

  Future<void> logLogout() => _emit(kEventLogout);

  // ---------------------------------------------------------------------------
  // Sync events
  // ---------------------------------------------------------------------------

  Future<void> logSyncStart({
    required String scope,
    required String trigger,
    String? courseId,
  }) =>
      _emit(kEventSyncStart, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamTrigger: trigger,
      });

  Future<void> logSyncComplete({
    required String scope,
    required int durationMs,
    required int itemsSynced,
    String? courseId,
  }) =>
      _emit(kEventSyncComplete, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamDurationMs: durationMs,
        kParamItemsSynced: itemsSynced,
      });

  Future<void> logSyncFailure({
    required String scope,
    required int durationMs,
    required String stage,
    required String errorKind,
    String? courseId,
  }) =>
      _emit(kEventSyncFailure, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamDurationMs: durationMs,
        kParamStage: stage,
        kParamErrorKind: errorKind,
      });

  // ---------------------------------------------------------------------------
  // List-selection events
  // ---------------------------------------------------------------------------

  Future<void> logOnboardingListSelectionCompleted({
    required int listCount,
    required bool hasAllEnrolled,
    required bool hasMyLists,
    required int availableCount,
  }) =>
      _emit(kEventOnboardingListSelectionCompleted, {
        kParamListCount: listCount,
        kParamHasAllEnrolled: hasAllEnrolled,
        kParamHasMyLists: hasMyLists,
        kParamAvailableCount: availableCount,
      });

  Future<void> logSettingsListSelectionChanged({
    required int listCount,
    required int listsAdded,
    required int listsRemoved,
    required bool hasAllEnrolled,
    required bool hasMyLists,
  }) =>
      _emit(kEventSettingsListSelectionChanged, {
        kParamListCount: listCount,
        kParamListsAdded: listsAdded,
        kParamListsRemoved: listsRemoved,
        kParamHasAllEnrolled: hasAllEnrolled,
        kParamHasMyLists: hasMyLists,
      });

  // ---------------------------------------------------------------------------
  // Download events
  // ---------------------------------------------------------------------------

  Future<void> logDownloadStart({
    required String scope,
    required String courseId,
    required int videoCount,
    String? blockId,
  }) =>
      _emit(kEventDownloadStart, {
        kParamScope: scope,
        kParamCourseId: courseId,
        if (blockId != null) kParamBlockId: blockId,
        kParamVideoCount: videoCount,
      });

  Future<void> logDownloadComplete({
    required String scope,
    required String courseId,
    required int durationMs,
    required int bytesDownloaded,
    required int videoCount,
    String? blockId,
  }) =>
      _emit(kEventDownloadComplete, {
        kParamScope: scope,
        kParamCourseId: courseId,
        if (blockId != null) kParamBlockId: blockId,
        kParamDurationMs: durationMs,
        kParamBytesDownloaded: bytesDownloaded,
        kParamVideoCount: videoCount,
      });

  Future<void> logDownloadFailure({
    required String scope,
    required String courseId,
    required String errorKind,
    required int videosCompleted,
    required int videosTotal,
    String? blockId,
  }) =>
      _emit(kEventDownloadFailure, {
        kParamScope: scope,
        kParamCourseId: courseId,
        if (blockId != null) kParamBlockId: blockId,
        kParamErrorKind: errorKind,
        kParamVideosCompleted: videosCompleted,
        kParamVideosTotal: videosTotal,
      });

  // ---------------------------------------------------------------------------
  // Course events
  // ---------------------------------------------------------------------------

  Future<void> logCourseView({
    required String courseId,
    required String source,
  }) =>
      _emit(kEventCourseView, {
        kParamCourseId: courseId,
        kParamSource: source,
      });

  Future<void> logSectionOpen({
    required String courseId,
    required String blockId,
    required int sectionIndex,
  }) =>
      _emit(kEventSectionOpen, {
        kParamCourseId: courseId,
        kParamBlockId: blockId,
        kParamSectionIndex: sectionIndex,
      });

  Future<void> logSectionPlay({
    required String courseId,
    required String blockId,
  }) =>
      _emit(kEventSectionPlay, {
        kParamCourseId: courseId,
        kParamBlockId: blockId,
      });

  // ---------------------------------------------------------------------------
  // Video events
  // ---------------------------------------------------------------------------

  Future<void> logVideoPlay({
    required String courseId,
    required String videoBlockId,
    required int positionS,
    required int durationS,
    required bool isResume,
  }) =>
      _emit(kEventVideoPlay, {
        kParamCourseId: courseId,
        kParamVideoBlockId: videoBlockId,
        kParamPositionS: positionS,
        kParamDurationS: durationS,
        kParamIsResume: isResume,
      });

  Future<void> logVideoPause({
    required String courseId,
    required String videoBlockId,
    required int positionS,
    required int durationS,
  }) =>
      _emit(kEventVideoPause, {
        kParamCourseId: courseId,
        kParamVideoBlockId: videoBlockId,
        kParamPositionS: positionS,
        kParamDurationS: durationS,
      });

  Future<void> logVideoComplete({
    required String courseId,
    required String videoBlockId,
    required int durationS,
  }) =>
      _emit(kEventVideoComplete, {
        kParamCourseId: courseId,
        kParamVideoBlockId: videoBlockId,
        kParamDurationS: durationS,
      });

  Future<void> logVideoScrub({
    required String courseId,
    required String videoBlockId,
    required int fromPositionS,
    required int toPositionS,
    required int durationS,
  }) =>
      _emit(kEventVideoScrub, {
        kParamCourseId: courseId,
        kParamVideoBlockId: videoBlockId,
        kParamFromPositionS: fromPositionS,
        kParamToPositionS: toPositionS,
        kParamDurationS: durationS,
      });
}
