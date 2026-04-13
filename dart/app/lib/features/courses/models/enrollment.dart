// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'enrollment.freezed.dart';
part 'enrollment.g.dart';

@freezed
abstract class CourseMeta with _$CourseMeta {
  const factory CourseMeta({
    @JsonKey(name: 'feature_image_src') String? featureImageSrc,
    String? description,
  }) = _CourseMeta;

  factory CourseMeta.fromJson(Map<String, dynamic> json) =>
      _$CourseMetaFromJson(json);
}

@freezed
abstract class CourseRun with _$CourseRun {
  const factory CourseRun({
    required String title,
    required String coursewareId,
    required String coursewareUrl,
    required String? startDate,
    required String? endDate,
    required String runTag,
    required String courseNumber,
    CourseMeta? course,
  }) = _CourseRun;

  factory CourseRun.fromJson(Map<String, dynamic> json) =>
      _$CourseRunFromJson(json);
}

@freezed
abstract class Enrollment with _$Enrollment {
  const factory Enrollment({
    required int id,
    required String enrollmentMode,
    required CourseRun run,
  }) = _Enrollment;

  factory Enrollment.fromJson(Map<String, dynamic> json) =>
      _$EnrollmentFromJson(json);
}
