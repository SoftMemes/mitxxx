import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';

/// OCW courses currently in the user's sync selection. Unlike MITx — where
/// the home screen derives course metadata from a cached enrollments JSON
/// blob — OCW metadata lives in its own `cached_ocw_courses` table, populated
/// by `_fetchOcwCourse` in the sync pipeline.
///
/// Yields an empty list before the first reconciliation sync completes.
///
/// Implemented as a plain `StreamProvider` (not `@riverpod`-generated) to
/// avoid a known build-order bug where `riverpod_generator` can't resolve
/// Drift-generated table row classes on a clean build.
// ignore: specify_nonobvious_property_types
final activeOcwCoursesProvider =
    StreamProvider.autoDispose<List<CachedOcwCourse>>((ref) async* {
  final db = ref.read(appDatabaseProvider);
  await for (final memberships in db.select(db.courseListMemberships).watch()) {
    final allowed = memberships
        .map((m) => m.courseId)
        .where((id) => id.startsWith('ocw:'))
        .toSet();
    if (allowed.isEmpty) {
      yield const [];
      continue;
    }
    final rows = await (db.select(db.cachedOcwCourses)
          ..where((t) => t.courseId.isIn(allowed)))
        .get();
    yield rows;
  }
});

/// Stream of one OCW course by id. Null until the sync pipeline has written
/// a `cached_ocw_courses` row for it.
// ignore: specify_nonobvious_property_types
final ocwCourseProvider = StreamProvider.autoDispose
    .family<CachedOcwCourse?, String>((ref, courseId) {
  final db = ref.read(appDatabaseProvider);
  return db.watchOcwCourse(courseId);
});
