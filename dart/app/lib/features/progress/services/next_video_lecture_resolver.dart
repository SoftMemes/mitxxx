import 'dart:convert';

import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/outline.dart';
import 'package:omnilect/features/courses/models/sequence.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';

/// Walks course outlines to find the next lecture that actually has playable
/// video. Used by `ProgressTracker.recordCompletion` to advance the tracked
/// lecture after a user finishes one.
class NextVideoLectureResolver {
  NextVideoLectureResolver(this.db);

  final AppDatabase db;

  /// Returns the block id of the first video-bearing sequence **after**
  /// [fromSequenceId] in [courseId]'s flattened outline. Returns `null` when
  /// [fromSequenceId] is missing from the outline or when no further sequence
  /// has at least one vertical with a video.
  Future<String?> nextMitxVideoSequence({
    required String courseId,
    required String fromSequenceId,
  }) async {
    final outline = await _loadOutline(courseId);
    if (outline == null) return null;

    final allSequenceIds = outline.outline.sections
        .expand((s) => s.sequenceIds)
        .toList();
    final idx = allSequenceIds.indexOf(fromSequenceId);
    if (idx < 0) return null;

    for (var i = idx + 1; i < allSequenceIds.length; i++) {
      final seqId = allSequenceIds[i];
      if (await _sequenceHasVideo(seqId)) {
        return seqId;
      }
    }
    return null;
  }

  /// Returns the `lectureId` of the first OCW lecture **after**
  /// [fromLectureId] with a non-null `mp4Url`. Returns `null` when
  /// [fromLectureId] is missing or no later lecture has a downloadable video.
  Future<String?> nextOcwVideoLecture({
    required String courseId,
    required String fromLectureId,
  }) async {
    final lectures = await db.getOcwLectures(courseId);
    final idx = lectures.indexWhere((l) => l.lectureId == fromLectureId);
    if (idx < 0) return null;

    for (var i = idx + 1; i < lectures.length; i++) {
      if (lectures[i].mp4Url != null) return lectures[i].lectureId;
    }
    return null;
  }

  Future<CourseOutline?> _loadOutline(String courseId) async {
    final row = await db.getOutline(courseId);
    if (row == null) return null;
    try {
      return CourseOutline.fromJson(
        jsonDecode(row.data) as Map<String, dynamic>,
      );
    } on Object {
      return null;
    }
  }

  Future<bool> _sequenceHasVideo(String sequenceId) async {
    final seqRow = await db.getSequence(sequenceId);
    if (seqRow == null) return false;
    final SequenceDetail seq;
    try {
      seq = SequenceDetail.fromJson(
        jsonDecode(seqRow.data) as Map<String, dynamic>,
      );
    } on Object {
      return false;
    }
    for (final item in seq.items) {
      final xblockRow = await db.getXblock(item.id);
      if (xblockRow == null) continue;
      try {
        final content = XBlockContent.fromJson(
          jsonDecode(xblockRow.data) as Map<String, dynamic>,
        );
        if (content.videos.any((v) => v.mp4Url != null || v.hlsUrl != null)) {
          return true;
        }
      } on Object {
        // Malformed row — treat as non-video and keep searching.
      }
    }
    return false;
  }
}
