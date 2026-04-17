// ignore_for_file: uri_has_not_been_generated
import 'package:drift/drift.dart' show Value;
import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
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

    // "All enrolled" — from mitxonline.
    try {
      final resp = await client.mitxOnline
          .get<List<dynamic>>('/api/v1/enrollments/');
      final count = resp.data?.length ?? 0;
      companions.add(
        AvailableListsCompanion.insert(
          listId: kAllEnrolledListId,
          source: ListSource.enrolled.storageValue,
          name: kAllEnrolledDisplayName,
          totalCourseCount: count,
          fetchedAt: now,
        ),
      );
    } on Object catch (e, st) {
      _log.warning('refresh: enrollments fetch failed', e, st);
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
    }

    // Custom lists from learn.mit.edu.
    try {
      await client.ensureLearnApiSession();
      final resp = await client.learnApi.get<Map<String, dynamic>>(
        '/api/v1/userlists/',
        queryParameters: {'limit': 100},
      );
      final results = (resp.data?['results'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
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
  }
}
