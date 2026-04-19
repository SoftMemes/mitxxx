import 'dart:async';

import 'package:dio/dio.dart';
import 'package:mitx_api/mitx_api.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/sync/fetchers/ocw_course_fetcher.dart';
import 'package:omnilect/features/sync/isolate/isolate_analytics.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart' show LogicalOp;
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// Injected-dependencies bundle passed to every [LogicalOp]. Constructed
/// once per isolate; shared by all ops.
///
/// [client] is mutable so the isolate can swap in a fresh [DioClient] after
/// cookies are reloaded post-reauth without rebuilding every op factory.
class OpContext {
  OpContext({
    required this.client,
    required this.db,
    required this.analytics,
    required this.ocwFetcher,
  });

  DioClient client;

  final AppDatabase db;
  final IsolateAnalytics analytics;
  final OcwCourseFetcher ocwFetcher;
}

/// Per-invocation, narrower view of what a single op needs. Combines the
/// shared [OpContext] with the op's own cancel token + event sink.
class OpRuntime {
  OpRuntime({
    required this.ctx,
    required this.token,
    required this.events,
  });

  final OpContext ctx;
  final CancelToken token;
  final EventSink<SyncEvent> events;

  DioClient get client => ctx.client;
  AppDatabase get db => ctx.db;
  IsolateAnalytics get analytics => ctx.analytics;
  OcwCourseFetcher get ocwFetcher => ctx.ocwFetcher;
}
