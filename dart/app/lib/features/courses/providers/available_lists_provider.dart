// ignore_for_file: uri_has_not_been_generated
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
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

    // No proactive session warm-up. The api.learn.mit.edu userlist call
    // below goes through the 401/403 interceptor on `client.learnApi`
    // (installed in `_attachLearnApiAuthInterceptor`) which silently
    // bootstraps and retries on stale-session errors, and the mitxonline
    // enrollments call either works with current cookies or surfaces
    // the reauth prompt via the `authFailed` branch below.

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
