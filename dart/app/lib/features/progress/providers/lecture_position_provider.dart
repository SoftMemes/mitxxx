import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/features/progress/providers/course_position_provider.dart';

@immutable
class LecturePositionKey {
  const LecturePositionKey({required this.courseId, required this.lectureId});

  final String courseId;
  final String lectureId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LecturePositionKey &&
          other.courseId == courseId &&
          other.lectureId == lectureId;

  @override
  int get hashCode => Object.hash(courseId, lectureId);
}

/// Returns the saved position (seconds) for a specific lecture, or `0` when
/// the course's tracked lecture doesn't match. Player screens read this on
/// init to decide whether to seek before first play.
// ignore: specify_nonobvious_property_types
final lecturePositionProvider =
    Provider.autoDispose.family<double, LecturePositionKey>((ref, key) {
  final async = ref.watch(courseWatchPositionProvider(key.courseId));
  final row = async.asData?.value;
  if (row == null) return 0;
  if (row.lectureId != key.lectureId) return 0;
  return row.positionSeconds;
});
