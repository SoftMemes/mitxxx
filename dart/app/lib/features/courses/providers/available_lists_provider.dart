// ignore_for_file: uri_has_not_been_generated
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/sync/providers/sync_providers.dart';
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

/// Refreshes the list-of-lists via the sync isolate. The actual HTTP +
/// cookie-jar IO happens there so the UI thread stays responsive during
/// pull-to-refresh; this controller just dispatches the request and awaits
/// completion. 401/403 responses raise `StaleSessionException` inside the
/// isolate, which the main-side `SessionRefreshManager` handles.
@Riverpod(keepAlive: true)
class AvailableListsController extends _$AvailableListsController {
  @override
  void build() {}

  Future<void> refresh() async {
    _log.info('refresh: awaiting sync manager');
    final manager = await ref.read(syncManagerProvider.future);
    if (manager == null) {
      _log.warning('refresh: no manager (signed out?) — skipping');
      return;
    }
    await manager.refreshAvailableLists();
    _log.info('refresh: sync isolate reports done');
  }
}
