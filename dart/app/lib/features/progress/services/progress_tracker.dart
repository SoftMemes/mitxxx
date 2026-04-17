import 'dart:async';
import 'dart:convert';

import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:omnilect/features/progress/services/next_video_lecture_resolver.dart';

/// Minimum gap between throttled position writes for a single course.
const Duration kProgressWriteThrottle = Duration(seconds: 5);

/// Returns true when [position] is within 2 s of [duration] — used as the
/// "end of lecture" threshold so we advance before `video_player` reports
/// the exact terminal position.
bool isLectureComplete(double position, double duration) {
  if (duration <= 0) return false;
  return position >= duration - 2;
}

/// Records and advances the user's "continue where you left off" position.
/// Writes are throttled per course; callers use [flushPosition] for moments
/// that must persist immediately (pause, seek, dispose, app-background).
///
/// Methods accept a `testClock` for deterministic unit tests; callers in the
/// app pass `null` (the default) so [DateTime.now] is used.
class ProgressTracker {
  ProgressTracker({
    required this.db,
    required this.resolver,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final NextVideoLectureResolver resolver;
  final DateTime Function() _clock;

  final Map<String, DateTime> _lastWriteAt = {};

  /// Throttled write. Coalesces rapid calls so we don't hammer SQLite on
  /// every playback tick; at least [kProgressWriteThrottle] elapses between
  /// persists for the same [courseId].
  Future<void> recordPosition({
    required String courseId,
    required String lectureId,
    required double positionSeconds,
  }) async {
    final now = _clock();
    final last = _lastWriteAt[courseId];
    if (last != null && now.difference(last) < kProgressWriteThrottle) {
      return;
    }
    _lastWriteAt[courseId] = now;
    await db.upsertCoursePosition(
      courseId: courseId,
      lectureId: lectureId,
      positionSeconds: positionSeconds,
    );
  }

  /// Immediate, non-throttled write. Call on pause, seek, dispose,
  /// app-backgrounded, and any time position loss would be user-visible.
  Future<void> flushPosition({
    required String courseId,
    required String lectureId,
    required double positionSeconds,
  }) async {
    _lastWriteAt[courseId] = _clock();
    await db.upsertCoursePosition(
      courseId: courseId,
      lectureId: lectureId,
      positionSeconds: positionSeconds,
    );
  }

  /// Called when the player reports end-of-lecture. Advances the row to the
  /// next video-bearing lecture at position 0, or clears the row when none
  /// remains. Skips all work when [completedLectureId] is no longer the
  /// tracked lecture (user moved on).
  Future<void> recordCompletion({
    required String courseId,
    required String completedLectureId,
  }) async {
    final current = await db.getCoursePosition(courseId);
    if (current == null || current.lectureId != completedLectureId) return;

    final isOcw = courseId.startsWith('ocw:');
    final nextId = isOcw
        ? await resolver.nextOcwVideoLecture(
            courseId: courseId,
            fromLectureId: completedLectureId,
          )
        : await resolver.nextMitxVideoSequence(
            courseId: courseId,
            fromSequenceId: completedLectureId,
          );

    _lastWriteAt[courseId] = _clock();
    if (nextId == null) {
      await db.deleteCoursePosition(courseId);
    } else {
      await db.upsertCoursePosition(
        courseId: courseId,
        lectureId: nextId,
        positionSeconds: 0,
      );
    }
  }

  /// Drops the tracked row when the stored lectureId is no longer present in
  /// the course outline after a sync. Silently no-ops for courses that have
  /// no row or whose row still points at a valid lecture.
  Future<void> validateTrackedLecture(String courseId) async {
    final current = await db.getCoursePosition(courseId);
    if (current == null) return;
    final exists = courseId.startsWith('ocw:')
        ? await _ocwLectureExists(courseId, current.lectureId)
        : await _mitxSequenceExists(courseId, current.lectureId);
    if (!exists) {
      await db.deleteCoursePosition(courseId);
    }
  }

  Future<bool> _mitxSequenceExists(String courseId, String sequenceId) async {
    final row = await db.getOutline(courseId);
    if (row == null) return false;
    try {
      final outline = CourseOutline.fromJson(
        jsonDecode(row.data) as Map<String, dynamic>,
      );
      return outline.outline.sections
          .expand((s) => s.sequenceIds)
          .contains(sequenceId);
    } on Object {
      return false;
    }
  }

  Future<bool> _ocwLectureExists(String courseId, String lectureId) async {
    final lecture = await db.getOcwLecture(lectureId);
    return lecture != null && lecture.courseId == courseId;
  }
}
