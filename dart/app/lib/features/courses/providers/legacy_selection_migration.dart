import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'legacy_selection_migration.g.dart';

final _log = Logger('legacy_selection_migration');

/// One-shot migration for users who upgrade from a build that predates the
/// course-shortlist-sync feature. If the user has any locally-cached courses
/// but no selected lists, synthesize the "All enrolled" row so they get the
/// same behavior as before the change — no onboarding prompt forced on them.
///
/// Idempotent: no-op on every subsequent launch. Fresh installs are excluded
/// naturally because they have no cached courses.
@Riverpod(keepAlive: true)
Future<void> legacySelectionMigration(Ref ref) async {
  final db = ref.read(appDatabaseProvider);

  final existingSelection = await db.getSelectedLists();
  if (existingSelection.isNotEmpty) return;

  final hasCachedEnrollments = await db.getEnrollments() != null;
  final cachedCourseCount = await (db.selectOnly(db.cachedCourseSync)
        ..addColumns([db.cachedCourseSync.courseId]))
      .get();
  final hasLocalCourses = hasCachedEnrollments || cachedCourseCount.isNotEmpty;
  if (!hasLocalCourses) return;

  _log.info('migrating legacy user to all-enrolled selection');
  await db.replaceSelectedLists([
    SelectedListsCompanion.insert(
      listId: kAllEnrolledListId,
      source: ListSource.enrolled.storageValue,
      name: kAllEnrolledDisplayName,
      selectedAt: DateTime.now(),
    ),
  ]);
}
