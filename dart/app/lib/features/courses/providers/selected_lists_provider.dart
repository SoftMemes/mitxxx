import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'selected_lists_provider.g.dart';

/// Watches the user's selected lists. UI subscribes to this.
@riverpod
Stream<List<AppListSelection>> selectedLists(Ref ref) {
  final db = ref.read(appDatabaseProvider);
  return db.watchSelectedLists().map(
        (rows) => rows
            .map(
              (row) => AppListSelection(
                id: row.listId,
                source: ListSource.fromStorage(row.source),
                name: row.name,
                selectedAt: row.selectedAt,
              ),
            )
            .toList(),
      );
}

/// Convenience: true iff the user has at least one selected list. Used by the
/// router to gate entry into the list-selection onboarding step.
@riverpod
Stream<bool> hasSelectedLists(Ref ref) {
  final db = ref.read(appDatabaseProvider);
  return db.watchSelectedLists().map((rows) => rows.isNotEmpty);
}

/// Commits selection changes. Takes the set of list ids the user has chosen
/// and rewrites the `selected_lists` table accordingly. The caller is
/// responsible for kicking off the reconciliation sync afterwards (the sync
/// controller reads the current selection).
@Riverpod(keepAlive: true)
class SelectedListsController extends _$SelectedListsController {
  @override
  void build() {}

  /// Replace the current selection with the rows identified by [listIds].
  /// Names and sources are looked up from the `available_lists` cache so the
  /// saved selection has stable display metadata even when offline.
  Future<void> setSelection(Set<String> listIds) async {
    final db = ref.read(appDatabaseProvider);
    final available = {
      for (final row in await db.getAvailableLists()) row.listId: row,
    };

    final now = DateTime.now();
    final companions = <SelectedListsCompanion>[];
    for (final id in listIds) {
      final row = available[id];
      final source = row?.source ??
          (id == kAllEnrolledListId
              ? ListSource.enrolled.storageValue
              : ListSource.learnMyList.storageValue);
      final name = row?.name ??
          (id == kAllEnrolledListId ? kAllEnrolledDisplayName : '');
      companions.add(
        SelectedListsCompanion.insert(
          listId: id,
          source: source,
          name: name,
          selectedAt: now,
        ),
      );
    }

    await db.replaceSelectedLists(companions);
  }
}
