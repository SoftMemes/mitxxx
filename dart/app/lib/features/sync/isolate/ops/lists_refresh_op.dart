import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/ops/op_helpers.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

final _log = Logger('sync.lists');

/// Refresh the userlists and rebuild memberships, without fetching any
/// per-course content. Used e.g. when the list picker opens.
class ListsRefreshOp extends LogicalOp {
  ListsRefreshOp({
    required super.request,
    required super.cancelToken,
    required super.events,
    required this.ctx,
  });

  final OpContext ctx;

  @override
  Future<void> run() async {
    final runtime = OpRuntime(ctx: ctx, token: cancelToken, events: events);
    final started = DateTime.now();

    runtime.analytics.logSyncStart(scope: 'lists', trigger: trigger);
    runtime.events.add(const ScopeStateChanged(
      ScopeIds.lists,
      ScopeState(status: ScopeStatus.syncing),
    ));

    // Eagerly refresh the api.learn.mit.edu session — stale `session`
    // silently returns 200-empty on userlists, which would wipe membership.
    try {
      await ensureFreshLearnSession(runtime);
    } on StaleSessionException {
      runtime.events.add(const ScopeStateChanged(ScopeIds.lists, ScopeState()));
      rethrow;
    }

    // Enrollments are needed to filter mitxonline list items to "things we
    // are enrolled in"; keep the same subset of syncAll behavior.
    List<Enrollment> enrollments;
    try {
      enrollments = await fetchEnrollments(runtime);
    } on StaleSessionException {
      runtime.events.add(const ScopeStateChanged(ScopeIds.lists, ScopeState()));
      rethrow;
    } on Object catch (e, st) {
      _log.warning('listsRefresh: enrollment fetch failed', e, st);
      runtime.events.add(const ScopeStateChanged(
        ScopeIds.lists,
        ScopeState(status: ScopeStatus.error),
      ));
      runtime.analytics.logSyncFailure(
        scope: 'lists',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'enrollments',
        errorKind: 'network',
      );
      return;
    }

    try {
      await reconcileMembership(runtime, enrollments);
    } on StaleSessionException {
      runtime.events.add(const ScopeStateChanged(ScopeIds.lists, ScopeState()));
      rethrow;
    } on Object catch (e, st) {
      _log.warning('listsRefresh: reconciliation failed', e, st);
      runtime.events.add(const ScopeStateChanged(
        ScopeIds.lists,
        ScopeState(status: ScopeStatus.error),
      ));
      runtime.analytics.logSyncFailure(
        scope: 'lists',
        durationMs: DateTime.now().difference(started).inMilliseconds,
        stage: 'reconcile',
        errorKind: 'unknown',
      );
      return;
    }

    runtime.events.add(const ScopeStateChanged(ScopeIds.lists, ScopeState()));
    runtime.analytics.logSyncComplete(
      scope: 'lists',
      durationMs: DateTime.now().difference(started).inMilliseconds,
    );
  }
}
