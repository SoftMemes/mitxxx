// ignore_for_file: uri_has_not_been_generated
import 'dart:io';

import 'package:emajtee/core/analytics/analytics_events.dart';
import 'package:emajtee/core/analytics/analytics_preferences.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'analytics_service.g.dart';

final _analyticsLog = Logger('analytics');

/// Central analytics service. All Firebase Analytics calls route through here.
///
/// Instantiated as a Riverpod provider so it can react to the user's opt-in
/// preference. When opted out, all [logX] methods no-op and Firebase
/// collection is disabled.
@Riverpod(keepAlive: true)
AnalyticsService analyticsService(Ref ref) {
  final optedIn = ref
      .watch(analyticsPreferencesProvider.select((v) => v.valueOrNull ?? true));
  // Sync the Firebase SDK's collection state whenever the preference changes.
  FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(optedIn);
  return AnalyticsService._(optedIn: optedIn);
}

class AnalyticsService {
  AnalyticsService._({required this.optedIn});

  final bool optedIn;
  final _analytics = FirebaseAnalytics.instance;

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
    await _analytics.logEvent(name: name, parameters: params?.cast());
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
    String? courseId,
    required String trigger,
  }) =>
      _emit(kEventSyncStart, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamTrigger: trigger,
      });

  Future<void> logSyncComplete({
    required String scope,
    String? courseId,
    required int durationMs,
    required int itemsSynced,
  }) =>
      _emit(kEventSyncComplete, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamDurationMs: durationMs,
        kParamItemsSynced: itemsSynced,
      });

  Future<void> logSyncFailure({
    required String scope,
    String? courseId,
    required int durationMs,
    required String stage,
    required String errorKind,
  }) =>
      _emit(kEventSyncFailure, {
        kParamScope: scope,
        if (courseId != null) kParamCourseId: courseId,
        kParamDurationMs: durationMs,
        kParamStage: stage,
        kParamErrorKind: errorKind,
      });

  // ---------------------------------------------------------------------------
  // Download events
  // ---------------------------------------------------------------------------

  Future<void> logDownloadStart({
    required String scope,
    required String courseId,
    String? blockId,
    required int videoCount,
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
    String? blockId,
    required int durationMs,
    required int bytesDownloaded,
    required int videoCount,
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
    String? blockId,
    required String errorKind,
    required int videosCompleted,
    required int videosTotal,
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
