import 'package:omnilect/core/storage/database_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'unsupported_courses_provider.g.dart';

/// A learning resource that's in one of the user's selected lists but that
/// this app doesn't yet know how to sync (OCW, edX.org, etc.). Displayed on
/// the home screen with a "not yet supported" badge so the user can see what
/// they curated even though it can't be downloaded yet.
class UnsupportedCourse {
  const UnsupportedCourse({
    required this.id,
    required this.title,
    required this.platformCode,
  });

  final String id;
  final String title;
  final String platformCode;

  String get platformLabel {
    switch (platformCode) {
      case 'ocw':
        return 'MIT OpenCourseWare';
      case 'edx':
        return 'edX';
      default:
        return platformCode;
    }
  }
}

/// The deduplicated union of unsupported list items across every
/// currently-selected list. If the same resource appears in multiple lists
/// it's shown once.
///
/// Implemented as a `Future` (not a Drift `watch()` stream) because the
/// underlying table is written by the sync isolate; Drift's stream cache on
/// the main isolate doesn't pick up cross-isolate writes. The bridge fires
/// `ref.invalidate(unsupportedCoursesProvider)` on DbInvalidated('unsupported'),
/// which rebuilds this provider and re-runs the direct query against SQLite.
@riverpod
Future<List<UnsupportedCourse>> unsupportedCourses(Ref ref) async {
  final db = ref.read(appDatabaseProvider);
  final rows = await db.select(db.unsupportedListItems).get();
  final seen = <String, UnsupportedCourse>{};
  for (final row in rows) {
    seen.putIfAbsent(
      row.courseId,
      () => UnsupportedCourse(
        id: row.courseId,
        title: row.title,
        platformCode: row.platformCode,
      ),
    );
  }
  return seen.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
}
