import 'dart:async';

import 'package:dio/dio.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// Base type for a single logical sync operation (full sync, course sync,
/// lecture sync, lists refresh). Implementations are **isolate-safe** — they
/// must not import Flutter or Riverpod.
///
/// Ops are constructed by an [OpFactory] when the state machine decides to
/// start one. They run once; their [run] future completes normally on
/// success, with a `StaleSessionException` on 401/403, or with any other
/// error on a terminal failure. Per-scope errors inside the op are reported
/// via [events] and do NOT cause [run] to throw.
abstract class LogicalOp {
  LogicalOp({
    required this.request,
    required this.cancelToken,
    required this.events,
  });

  final SyncRequest request;
  final CancelToken cancelToken;
  final EventSink<SyncEvent> events;

  String get scopeId => request.scopeId;
  String get trigger => request.trigger;

  /// Run the op. See class docs for error semantics.
  Future<void> run();
}

/// Builds [LogicalOp] instances from [SyncRequest]s. Injected into the sync
/// manager core so tests can substitute fakes.
typedef OpFactory = LogicalOp Function(
  SyncRequest request,
  CancelToken token,
  EventSink<SyncEvent> events,
);
