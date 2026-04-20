import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';

/// OCW courses currently in the user's sync selection. Unlike MITx — where
/// the home screen derives course metadata from a cached enrollments JSON
/// blob — OCW metadata lives in its own `cached_ocw_courses` table, populated
/// by `_fetchOcwCourse` in the sync pipeline.
///
/// Returns an empty list before the first reconciliation sync completes.
///
/// Implemented as a `FutureProvider` (not a Drift `watch()` stream) because
/// memberships + OCW rows are written by the sync isolate; Drift's stream
/// cache on the main isolate doesn't pick up cross-isolate writes. The
/// bridge fires `ref.invalidate(activeOcwCoursesProvider)` on
/// DbInvalidated('memberships') and DbInvalidated('ocwCourse'), which
/// rebuilds this provider and re-runs direct queries against SQLite.
// ignore: specify_nonobvious_property_types
final activeOcwCoursesProvider =
    FutureProvider.autoDispose<List<CachedOcwCourse>>((ref) async {
  final db = ref.read(appDatabaseProvider);
  final memberships = await db.select(db.courseListMemberships).get();
  final allowed = memberships
      .map((m) => m.courseId)
      .where((id) => id.startsWith('ocw:'))
      .toSet();
  if (allowed.isEmpty) return const [];
  return (db.select(db.cachedOcwCourses)
        ..where((t) => t.courseId.isIn(allowed)))
      .get();
});

/// Stream of one OCW course by id. Null until the sync pipeline has written
/// a `cached_ocw_courses` row for it.
// ignore: specify_nonobvious_property_types
final ocwCourseProvider = StreamProvider.autoDispose
    .family<CachedOcwCourse?, String>((ref, courseId) {
  final db = ref.read(appDatabaseProvider);
  return db.watchOcwCourse(courseId);
});
