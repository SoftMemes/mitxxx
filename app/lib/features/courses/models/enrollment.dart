import 'package:freezed_annotation/freezed_annotation.dart';

part 'enrollment.freezed.dart';
part 'enrollment.g.dart';

@freezed
class CourseRun with _$CourseRun {
  const factory CourseRun({
    required String title,
    required String coursewareId,
    required String coursewareUrl,
    required String? startDate,
    required String? endDate,
    required String runTag,
    required String courseNumber,
  }) = _CourseRun;

  factory CourseRun.fromJson(Map<String, dynamic> json) =>
      _$CourseRunFromJson(json);
}

@freezed
class Enrollment with _$Enrollment {
  const factory Enrollment({
    required int id,
    required String enrollmentMode,
    required CourseRun run,
  }) = _Enrollment;

  factory Enrollment.fromJson(Map<String, dynamic> json) =>
      _$EnrollmentFromJson(json);
}
