import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart'
    show kAllEnrolledDisplayName, kAllEnrolledListId;
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';
import 'package:omnilect/features/sync/isolate/ops/op_helpers.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

final _log = Logger('sync.available-lists');

/// Refreshes `available_lists` (Settings → Courses list picker + onboarding).
///
/// Ported from the main-isolate `AvailableListsController.refresh()` so the
/// HTTP + cookie-jar IO stops blocking the UI thread. Auth failures raise
/// [StaleSessionException] and rely on the main-side
/// `SessionRefreshManager` to resolve — matches every other op.
class AvailableListsRefreshOp extends LogicalOp {
  AvailableListsRefreshOp({
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

    _log.info('availableListsRefresh: START trigger=$trigger');
    runtime.events.add(const ScopeStateChanged(
      ScopeIds.availableLists,
      ScopeState(status: ScopeStatus.syncing),
    ));

    // Eagerly refresh the api.learn.mit.edu session — stale `session`
    // silently returns 200-empty on userlists, which would wipe the
    // custom-lists portion of `available_lists` below.
    try {
      await ensureFreshLearnSession(runtime);
    } on StaleSessionException {
      runtime.events.add(const ScopeStateChanged(
        ScopeIds.availableLists,
        ScopeState(),
      ));
      rethrow;
    }

    final now = DateTime.now();
    final companions = <AvailableListsCompanion>[];

    // "All enrolled" — via the learn.mit.edu v3 proxy (mitxonline v1 is
    // being deprecated).
    try {
      final t0 = DateTime.now();
      final resp = await runtime.client.learnApi.get<dynamic>(
        '/mitxonline/api/v3/enrollments/',
        cancelToken: runtime.token,
      );
      final list = resp.data as List<dynamic>;
      _log.info(
        'availableListsRefresh: enrollments fetched count=${list.length} '
        'in ${DateTime.now().difference(t0).inMilliseconds}ms',
      );
      companions.add(
        AvailableListsCompanion.insert(
          listId: kAllEnrolledListId,
          source: ListSource.enrolled.storageValue,
          name: kAllEnrolledDisplayName,
          totalCourseCount: list.length,
          fetchedAt: now,
        ),
      );
    } on DioException catch (e, st) {
      if (isStaleStatus(e)) {
        _log.warning('availableListsRefresh: enrollments stale-session');
        throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
      }
      _log.warning('availableListsRefresh: enrollments fetch failed', e, st);
      // Preserve prior "All enrolled" row so the list picker isn't wiped.
      final existing = await (runtime.db.select(runtime.db.availableLists)
            ..where((t) => t.listId.equals(kAllEnrolledListId)))
          .getSingleOrNull();
      if (existing != null) {
        companions.add(
          AvailableListsCompanion(
            listId: Value(existing.listId),
            source: Value(existing.source),
            name: Value(existing.name),
            totalCourseCount: Value(existing.totalCourseCount),
            fetchedAt: Value(existing.fetchedAt),
          ),
        );
      }
    } on Object catch (e, st) {
      _log.warning(
        'availableListsRefresh: enrollments fetch failed (non-http)', e, st);
    }

    // Custom lists from learn.mit.edu.
    try {
      final t1 = DateTime.now();
      final resp = await runtime.client.learnApi.get<dynamic>(
        '/api/v1/userlists/',
        queryParameters: {'limit': 100},
        cancelToken: runtime.token,
      );
      _log.info(
        'availableListsRefresh: userlists round-trip '
        '${DateTime.now().difference(t1).inMilliseconds}ms',
      );
      final body = resp.data as Map<String, dynamic>;
      final results = (body['results'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      _log.info(
        'availableListsRefresh: userlists count=${body['count']} '
        'results=${results.length}',
      );
      for (final lst in results) {
        companions.add(
          AvailableListsCompanion.insert(
            listId: lst['id'].toString(),
            source: ListSource.learnMyList.storageValue,
            name: (lst['title'] as String?) ?? '',
            totalCourseCount: (lst['item_count'] as int?) ?? 0,
            fetchedAt: now,
          ),
        );
      }
    } on DioException catch (e, st) {
      if (isStaleStatus(e)) {
        throw StaleSessionException(kindForHost(e.requestOptions.uri), e);
      }
      _log.warning('availableListsRefresh: userlists fetch failed', e, st);
      final existing = await (runtime.db.select(runtime.db.availableLists)
            ..where((t) =>
                t.source.equals(ListSource.learnMyList.storageValue)))
          .get();
      for (final row in existing) {
        companions.add(
          AvailableListsCompanion(
            listId: Value(row.listId),
            source: Value(row.source),
            name: Value(row.name),
            totalCourseCount: Value(row.totalCourseCount),
            fetchedAt: Value(row.fetchedAt),
          ),
        );
      }
    } on Object catch (e, st) {
      _log.warning('availableListsRefresh: userlists fetch failed', e, st);
    }

    if (runtime.token.isCancelled) return;

    _log.info(
      'availableListsRefresh: writing ${companions.length} list(s) to DB',
    );
    await runtime.db.replaceAvailableLists(companions);

    // Main-isolate Drift watches on this table won't fire for a write that
    // happens on THIS isolate — emit an invalidation event instead.
    runtime.events.add(const DbInvalidated('availableLists'));

    runtime.events.add(const ScopeStateChanged(
      ScopeIds.availableLists,
      ScopeState(),
    ));

    final durationMs = DateTime.now().difference(started).inMilliseconds;
    _log.info('availableListsRefresh: COMPLETE in ${durationMs}ms');
  }
}
