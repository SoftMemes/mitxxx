import 'dart:async';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show BackgroundIsolateBinaryMessenger, RootIsolateToken;
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client.dart';
import 'package:omnilect/core/network/secure_cookie_store.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/sync/fetchers/ocw_course_fetcher.dart';
import 'package:omnilect/features/sync/isolate/isolate_analytics.dart';
import 'package:omnilect/features/sync/isolate/isolate_logger_bridge.dart';
import 'package:omnilect/features/sync/isolate/ops/available_lists_refresh_op.dart';
import 'package:omnilect/features/sync/isolate/ops/course_sync_op.dart';
import 'package:omnilect/features/sync/isolate/ops/full_sync_op.dart';
import 'package:omnilect/features/sync/isolate/ops/lecture_sync_op.dart';
import 'package:omnilect/features/sync/isolate/ops/lists_refresh_op.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/sync_manager_core.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// Payload passed into the isolate on spawn.
class SpawnBundle {
  const SpawnBundle({
    required this.rootToken,
    required this.mainPort,
  });
  final RootIsolateToken rootToken;
  final SendPort mainPort;
}

/// Top-level entry for the sync isolate. Must be a static function (not a
/// closure) so it survives the `Isolate.spawn` serialization barrier.
Future<void> syncIsolateEntry(SpawnBundle bundle) async {
  // Enable Flutter plugin channels inside this isolate (needed for
  // FlutterSecureStorage cookie jar + path_provider for the DB file).
  BackgroundIsolateBinaryMessenger.ensureInitialized(bundle.rootToken);

  final toMain = bundle.mainPort;
  final fromMain = ReceivePort();

  // Hand our SendPort to main so it can start sending us requests.
  toMain.send(fromMain.sendPort);

  // Stand up the logger bridge so everything we log shows in the main
  // isolate's pipeline (dev.log + Crashlytics).
  final loggerBridge = IsolateLoggerBridge(toMain)..start();
  final log = Logger('sync-isolate');

  // Dio client + cookie jar (re-loads from SecureCookieStore; shared file).
  late DioClient client;
  try {
    client = await DioClient.create(SecureCookieStore());
  } on Object catch (e, st) {
    log.severe('failed to build DioClient', e, st);
    toMain.send(const IsolateExited());
    fromMain.close();
    return;
  }

  final db = AppDatabase();
  final analytics = IsolateAnalytics(_EventSink(toMain));
  final ocwFetcher = OcwCourseFetcher();

  final ctx = OpContext(
    client: client,
    db: db,
    analytics: analytics,
    ocwFetcher: ocwFetcher,
  );

  final eventSink = _EventSink(toMain);

  LogicalOp buildOp(SyncRequest req, CancelToken token, EventSink<SyncEvent> events) {
    return switch (req) {
      FullSyncRequest() => FullSyncOp(
          request: req,
          cancelToken: token,
          events: events,
          ctx: ctx,
        ),
      ListsRefreshRequest() => ListsRefreshOp(
          request: req,
          cancelToken: token,
          events: events,
          ctx: ctx,
        ),
      CourseSyncRequest() => CourseSyncOp(
          request: req,
          cancelToken: token,
          events: events,
          ctx: ctx,
          courseId: req.courseId,
        ),
      LectureSyncRequest() => LectureSyncOp(
          request: req,
          cancelToken: token,
          events: events,
          ctx: ctx,
          courseId: req.courseId,
          sequenceId: req.sequenceId,
        ),
      AvailableListsRefreshRequest() => AvailableListsRefreshOp(
          request: req,
          cancelToken: token,
          events: events,
          ctx: ctx,
        ),
    };
  }

  final core = SyncManagerCore(events: eventSink, opFactory: buildOp);

  toMain.send(const IsolateReady());
  log.info('sync isolate ready');

  await for (final msg in fromMain) {
    if (msg is SyncRequest) {
      log.info('recv SyncRequest scope=${msg.scopeId} trigger=${msg.trigger}');
      core.submit(msg);
    } else if (msg is SessionRefreshCompleted) {
      log.info('recv SessionRefreshCompleted kind=${msg.kind}');
      // Reload cookies first so the next request uses the fresh jar.
      await _reloadCookies(ctx, log);
      core.onSessionRefreshCompleted(msg.kind);
    } else if (msg is SessionRefreshFailed) {
      log.info(
        'recv SessionRefreshFailed kind=${msg.kind} reason=${msg.reason}',
      );
      core.onSessionRefreshFailed(msg.kind, msg.reason);
    } else if (msg is ReloadCookies) {
      log.info('recv ReloadCookies');
      await _reloadCookies(ctx, log);
    } else if (msg is StopAll) {
      log.info('recv StopAll drainInFlight=${msg.drainInFlight}');
      await core.stopAndWait(drain: msg.drainInFlight);
    } else if (msg is Shutdown) {
      log.info('shutdown received');
      await core.stopAndWait();
      await loggerBridge.stop();
      await db.close();
      toMain.send(const IsolateExited());
      fromMain.close();
      break;
    }
  }
}

Future<void> _reloadCookies(OpContext ctx, Logger log) async {
  // Rebuild the whole DioClient from SecureCookieStore — cheapest way to
  // pick up cookies a fresh login wrote on the main isolate without
  // requiring a new DioClient method. No op is running during reauth, so
  // swapping the reference is safe.
  try {
    final fresh = await DioClient.create(SecureCookieStore());
    ctx.client = fresh;
    log.info('reloadCookies: DioClient rebuilt');
  } on Object catch (e, st) {
    log.warning('reloadCookies failed', e, st);
  }
}

/// Adapter from [SendPort] to [EventSink] so ops can emit events without
/// knowing about isolate plumbing.
class _EventSink implements EventSink<SyncEvent> {
  _EventSink(this._port);
  final SendPort _port;
  bool _closed = false;

  @override
  void add(SyncEvent event) {
    if (_closed) return;
    _port.send(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  void close() {
    _closed = true;
  }
}
