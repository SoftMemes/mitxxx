// ignore_for_file: uri_has_not_been_generated
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/learn_api_session_bootstrap.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'available_lists_provider.g.dart';

final _log = Logger('available_lists');

/// Synthetic list id for "All enrolled" — the only system list, always first.
const String kAllEnrolledListId = 'all-enrolled';
const String kAllEnrolledDisplayName = 'Enrolled';

/// Watches the cached list-of-lists. UI subscribes to this; the underlying
/// table is populated by [AvailableListsController.refresh].
@riverpod
Stream<List<AppListSummary>> availableLists(Ref ref) {
  final db = ref.read(appDatabaseProvider);
  return db.watchAvailableLists().map(
        (rows) => rows
            .map(
              (row) => AppListSummary(
                id: row.listId,
                source: ListSource.fromStorage(row.source),
                name: row.name,
                totalCourseCount: row.totalCourseCount,
              ),
            )
            .toList(),
      );
}

/// Refreshes the list-of-lists from both sources (mitxonline enrollments
/// count for "All enrolled", plus learn.mit.edu userlists). Writes the
/// result to [AppDatabase.replaceAvailableLists].
@Riverpod(keepAlive: true)
class AvailableListsController extends _$AvailableListsController {
  @override
  void build() {}

  Future<void> refresh() async {
    final client = ref.read(dioClientProvider);
    final db = ref.read(appDatabaseProvider);
    final now = DateTime.now();
    final companions = <AvailableListsCompanion>[];

    // Lift cookies from the webview's persistent jar (the webview is the
    // authoritative cookie store after login). `session_mitlearn` /
    // `learn_csrftoken` are set there during the login flow's redirect chain;
    // pulling them into Dio here is enough for userlists to authenticate
    // correctly, and avoids a separate server-side OAuth hop that was prone
    // to long chains on slow networks.
    try {
      await syncWebViewCookiesToDio(client, const [
        'sso.ol.mit.edu',
        'mitxonline.mit.edu',
        'courses.learn.mit.edu',
        'api.learn.mit.edu',
        'learn.mit.edu',
      ]);
    } on Object catch (e, st) {
      _log.warning('refresh: webview cookie sync failed', e, st);
    }

    // Check whether api.learn.mit.edu sees us as authenticated. A silently-
    // stale `session_mitlearn` returns 200 with `is_authenticated: false` and
    // makes userlists come back empty. If so, run the HeadlessWebView-backed
    // bootstrap to complete SSO against api.learn.mit.edu before we fetch
    // userlists.
    var learnAuthenticated = false;
    try {
      final me = await client.learnApi.get<dynamic>('/api/v0/users/me/');
      final body = me.data as Map<String, dynamic>;
      learnAuthenticated = body['is_authenticated'] == true;
      _log.info(
        'refresh: learnApi users/me is_authenticated=$learnAuthenticated '
        'username=${body['username']}',
      );
    } on Object catch (e, st) {
      _log.warning('refresh: learnApi users/me failed', e, st);
    }

    if (!learnAuthenticated) {
      _log.info(
        'refresh: learn-api session stale — bootstrapping via WebView',
      );
      try {
        await bootstrapLearnApiSession(client);
      } on Object catch (e, st) {
        _log.warning('refresh: learn-api bootstrap failed', e, st);
      }
    }

    // "All enrolled" — from mitxonline. Dio is configured with a JSON
    // Accept header, so `.data` comes back already decoded; we request
    // `<dynamic>` and cast rather than using `<List<dynamic>>` because the
    // latter can trip over Dio's generic dispatch on some SDK versions.
    var authFailed = false;
    try {
      final resp =
          await client.mitxOnline.get<dynamic>('/api/v1/enrollments/');
      final list = resp.data as List<dynamic>;
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
      _log.warning('refresh: enrollments fetch failed', e, st);
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) authFailed = true;
      final existing = await (db.select(db.availableLists)
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
      _log.warning('refresh: enrollments fetch failed (non-http)', e, st);
    }

    // Custom lists from learn.mit.edu.
    try {
      final resp = await client.learnApi.get<dynamic>(
        '/api/v1/userlists/',
        queryParameters: {'limit': 100},
      );
      final body = resp.data as Map<String, dynamic>;
      final results =
          (body['results'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      _log.info(
        'refresh: userlists fetched count=${body['count']} '
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
    } on Object catch (e, st) {
      _log.warning('refresh: userlists fetch failed', e, st);
      final existing = await (db.select(db.availableLists)
            ..where((t) => t.source.equals(ListSource.learnMyList.storageValue)))
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
    }

    await db.replaceAvailableLists(companions);

    // If the session looked stale, surface the re-auth prompt so the user can
    // sign back in. We reuse the sync controller's "sync all" operation as the
    // resume target — after reauth, sync runs and refreshes lists again.
    if (authFailed) {
      ref
          .read(reauthControllerProvider.notifier)
          .request(const SyncAllOperation());
    }
  }
}
