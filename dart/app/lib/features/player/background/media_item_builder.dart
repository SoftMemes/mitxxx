import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/enrollment.dart';
import 'package:omnilect/features/courses/models/outline.dart';

final _log = Logger('player.media-item');

/// Builds the `audio_service` [MediaItem] shown on the lock screen / media
/// notification for a given lecture.
///
/// Reads directly from the Drift cache (no network) so the build is cheap and
/// doesn't block the playback start path. If any metadata lookup fails the
/// builder degrades gracefully — at worst you get a [MediaItem] with the ids
/// as title and no artwork, rather than no media session at all.
class MediaItemBuilder {
  MediaItemBuilder(this._db);

  final AppDatabase _db;

  /// Build a [MediaItem] for an MITx lecture identified by
  /// [courseId] (`course-v1:...`) and [sequenceId] (sequence block id).
  /// [durationSeconds] should be the stitched total duration when known.
  Future<MediaItem> buildMitx({
    required String courseId,
    required String sequenceId,
    required double durationSeconds,
  }) async {
    String? courseTitle;
    String? sequenceTitle;
    String? imageUrl;

    try {
      final cached = await _db.getOutline(courseId);
      if (cached != null) {
        final outline = CourseOutline.fromJson(
          jsonDecode(cached.data) as Map<String, dynamic>,
        );
        courseTitle = outline.title;
        sequenceTitle = outline.outline.sequences[sequenceId]?.title;
      }
    } on Object catch (e) {
      _log.fine('outline lookup failed for $courseId: $e');
    }

    try {
      final enrollments = await _db.getEnrollments();
      if (enrollments != null) {
        final list = jsonDecode(enrollments.data) as List<dynamic>;
        for (final raw in list) {
          final enrollment =
              Enrollment.fromJson(raw as Map<String, dynamic>);
          if (enrollment.run.coursewareId == courseId) {
            imageUrl = enrollment.run.course?.featureImageSrc;
            break;
          }
        }
      }
    } on Object catch (e) {
      _log.fine('enrollment lookup failed for $courseId: $e');
    }

    return _buildItem(
      id: sequenceId,
      title: sequenceTitle ?? 'Lecture',
      album: courseTitle ?? '',
      imageUrl: imageUrl,
      durationSeconds: durationSeconds,
    );
  }

  /// Build a [MediaItem] for an OCW lecture identified by
  /// [courseId] (`ocw:<slug>`) and [lectureSlug].
  Future<MediaItem> buildOcw({
    required String courseId,
    required String lectureSlug,
    required double durationSeconds,
  }) async {
    String? courseTitle;
    String? lectureTitle;
    String? imageUrl;

    try {
      final course = await _db.getOcwCourse(courseId);
      if (course != null) {
        courseTitle = course.title;
        imageUrl = course.imageUrl;
      }
    } on Object catch (e) {
      _log.fine('ocw course lookup failed for $courseId: $e');
    }

    try {
      final lecture = await _db.getOcwLecture('$courseId/$lectureSlug');
      lectureTitle = lecture?.title;
    } on Object catch (e) {
      _log.fine('ocw lecture lookup failed for $courseId/$lectureSlug: $e');
    }

    return _buildItem(
      id: '$courseId/$lectureSlug',
      title: lectureTitle ?? 'Lecture',
      album: courseTitle ?? '',
      imageUrl: imageUrl,
      durationSeconds: durationSeconds,
    );
  }

  Future<MediaItem> _buildItem({
    required String id,
    required String title,
    required String album,
    required String? imageUrl,
    required double durationSeconds,
  }) async {
    final artUri = await _resolveArtUri(imageUrl);
    return MediaItem(
      id: id,
      title: title,
      album: album.isEmpty ? null : album,
      duration: durationSeconds > 0
          ? Duration(milliseconds: (durationSeconds * 1000).round())
          : null,
      artUri: artUri,
    );
  }

  /// Resolve the remote image URL to a playable URI. Prefers the cached local
  /// file if we've already downloaded it (both MITx and OCW feed through
  /// `CourseImageDownloader`); otherwise falls back to the remote URL, which
  /// `audio_service` will fetch itself. Returns null when no image is known —
  /// the plugin falls back to the app icon.
  Future<Uri?> _resolveArtUri(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return null;
    try {
      final cached = await _db.getCourseImage(imageUrl);
      if (cached != null && File(cached.localFilePath).existsSync()) {
        return Uri.file(cached.localFilePath);
      }
    } on Object catch (e) {
      _log.fine('course image lookup failed for $imageUrl: $e');
    }
    return Uri.tryParse(imageUrl);
  }
}
