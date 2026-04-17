// ignore_for_file: uri_has_not_been_generated
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/auth/utils/webview_cookie_sync.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'available_lists_provider.g.dart';

final _log = Logger('available_lists');

/// Synthetic list id for "All enrolled" — the only system list, always first.
const String kAllEnrolledListId = 'all-enrolled';
const String kAllEnrolledDisplayName = 'All enrolled';

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

    // Lift Keycloak identity cookies from the webview's persistent jar into
    // Dio's store. Users on pre-fix installs never had sso.ol.mit.edu cookies
    // captured during login; without them, the OAuth chain below bounces to
    // the SSO login page instead of completing silently.
    try {
      await syncWebViewCookiesToDio(client, const [
        'sso.ol.mit.edu',
        'mitxonline.mit.edu',
        'courses.learn.mit.edu',
      ]);
    } on Object catch (e, st) {
      _log.warning('refresh: webview cookie sync failed', e, st);
    }

    // Refresh SSO state serially before hitting either API. The LMS OAuth
    // chain walks mitxonline → sso.ol.mit.edu → LMS, refreshing all three
    // session cookies at once. Running the learn-api handshake afterwards
    // ensures sso.ol.mit.edu recognizes the fresh Keycloak identity and
    // redirects back to api.learn.mit.edu with `session_mitlearn`.
    try {
      await client.establishLmsSession();
    } on Object catch (e, st) {
      _log.warning('refresh: LMS session refresh failed, proceeding anyway',
          e, st);
    }
    try {
      await client.ensureLearnApiSession(force: true);
    } on Object catch (e, st) {
      _log.warning('refresh: learn-api session refresh failed', e, st);
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
