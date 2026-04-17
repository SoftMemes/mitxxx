import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';

/// Watches the single `course_positions` row for `courseId`. Emits `null`
/// while the course has no tracked lecture — the outline screen uses that
/// signal to hide the Continue section entirely.
// ignore: specify_nonobvious_property_types
final courseWatchPositionProvider =
    StreamProvider.autoDispose.family<CoursePosition?, String>((ref, courseId) {
  final db = ref.read(appDatabaseProvider);
  return db.watchCoursePosition(courseId);
});
