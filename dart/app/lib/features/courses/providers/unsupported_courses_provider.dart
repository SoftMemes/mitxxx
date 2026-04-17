// ignore_for_file: uri_has_not_been_generated
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

/// Streams the deduplicated union of unsupported list items across every
/// currently-selected list. If the same resource appears in multiple lists
/// it's shown once.
@riverpod
Stream<List<UnsupportedCourse>> unsupportedCourses(Ref ref) {
  final db = ref.read(appDatabaseProvider);
  return db.watchUnsupportedListItems().map((rows) {
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
  });
}
