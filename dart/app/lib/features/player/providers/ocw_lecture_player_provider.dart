import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/core/storage/database_provider.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/models/xblock_content.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_html_builder.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';
import 'package:omnilect/features/downloads/utils/resolve_playable_uri.dart';

/// Lightweight state for the OCW lecture screen. A single lecture has exactly
/// one segment (one video + one collapsible resource tile), so we don't need
/// the stitched-playback machinery from `LecturePlayerState`.
class OcwLectureViewState {
  const OcwLectureViewState({
    required this.lecture,
    required this.resources,
    required this.safeResourcesHtml,
    this.playableUri,
    this.remoteUrl,
  });

  final CachedOcwLecture lecture;
  final List<CachedOcwResource> resources;
  final String safeResourcesHtml;
  final Uri? playableUri;
  final String? remoteUrl;

  /// True when the lecture has no downloadable video (YouTube-only or in-class
  /// dissection with no recording).
  bool get hasVideo => lecture.mp4Url != null;
}

/// Provider arguments — combined so the family key hashes correctly.
@immutable
class OcwLectureArgs {
  const OcwLectureArgs({required this.courseId, required this.lectureSlug});

  final String courseId;
  final String lectureSlug;

  String get lectureId => '$courseId/$lectureSlug';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OcwLectureArgs &&
          other.courseId == courseId &&
          other.lectureSlug == lectureSlug;

  @override
  int get hashCode => Object.hash(courseId, lectureSlug);
}

Future<OcwLectureViewState> _loadOcwLectureState(
  AppDatabase db,
  OcwLectureArgs args,
) async {
  final lecture = await db.getOcwLecture(args.lectureId);
  if (lecture == null) {
    throw StateError('OCW lecture ${args.lectureId} not yet synced');
  }
  final allResources = await db.getOcwResources(args.courseId);
  final matched = allResources
      .where((r) => r.lectureId == lecture.lectureId)
      .toList();
  final modelResources = matched
      .map((r) => OcwResource(
            id: r.resourceId,
            type: _decodeType(r.type),
            title: r.title,
            url: r.url,
            lectureId: r.lectureId,
          ))
      .toList();
  final rawHtml = buildOcwResourceHtml(modelResources);
  final safeHtml = sanitizeXBlockHtml(rawHtml);

  Uri? playable;
  final mp4 = lecture.mp4Url;
  if (mp4 != null) {
    playable = await resolvePlayableUri(
      ParsedVideoBlock(
        videoBlockId: lecture.lectureId,
        mp4Url: mp4,
        hlsUrl: null,
        duration: (lecture.durationSeconds ?? 0).toDouble(),
        transcriptLanguages: const {},
        transcriptTranslationUrl: null,
      ),
      db,
    );
  }

  return OcwLectureViewState(
    lecture: lecture,
    resources: matched,
    safeResourcesHtml: safeHtml,
    playableUri: playable,
    remoteUrl: mp4,
  );
}

OcwResourceType _decodeType(String name) {
  for (final t in OcwResourceType.values) {
    if (t.name == name) return t;
  }
  return OcwResourceType.lectureNotes;
}

// ignore: specify_nonobvious_property_types
final ocwLecturePlayerProvider = FutureProvider.autoDispose
    .family<OcwLectureViewState, OcwLectureArgs>((ref, args) async {
  final db = ref.read(appDatabaseProvider);
  return _loadOcwLectureState(db, args);
});
