// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'ocw_course.freezed.dart';
part 'ocw_course.g.dart';

/// Downloadable resource types surfaced next to OCW lectures (v1).
///
/// The `@JsonValue` strings match `OcwResourceType` values in
/// `python-tools/ocw-client/client.py`. The DB column stores the Dart .name
/// string (`lectureNotes` / `lectureSlides`) — see
/// `CachedOcwResources.type` in `app_database.dart`.
enum OcwResourceType {
  @JsonValue('lecture-notes')
  lectureNotes,
  @JsonValue('lecture-slides')
  lectureSlides,
}

@freezed
abstract class OcwResource with _$OcwResource {
  const factory OcwResource({
    required String id,
    required OcwResourceType type,
    required String title,
    required String url,
    String? lectureId,
  }) = _OcwResource;

  factory OcwResource.fromJson(Map<String, dynamic> json) =>
      _$OcwResourceFromJson(json);
}

@freezed
abstract class OcwLecture with _$OcwLecture {
  const factory OcwLecture({
    required String id,
    required String slug,
    required String title,
    required String sectionTitle,
    required int sectionOrder,
    required int lectureOrder,
    String? mp4Url,
    int? durationSeconds,
    @Default(<OcwResource>[]) List<OcwResource> resources,
  }) = _OcwLecture;

  factory OcwLecture.fromJson(Map<String, dynamic> json) =>
      _$OcwLectureFromJson(json);
}

@freezed
abstract class OcwSection with _$OcwSection {
  const factory OcwSection({
    required String title,
    required int order,
    @Default(<OcwLecture>[]) List<OcwLecture> lectures,
  }) = _OcwSection;

  factory OcwSection.fromJson(Map<String, dynamic> json) =>
      _$OcwSectionFromJson(json);
}

@freezed
abstract class OcwCourse with _$OcwCourse {
  const factory OcwCourse({
    required String id,
    required String slug,
    required String title,
    required String courseNumber,
    required String description,
    String? imageUrl,
    @Default(<OcwSection>[]) List<OcwSection> sections,
    @Default(<OcwResource>[]) List<OcwResource> orphanResources,
  }) = _OcwCourse;

  factory OcwCourse.fromJson(Map<String, dynamic> json) =>
      _$OcwCourseFromJson(json);
}
