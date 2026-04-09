import 'package:freezed_annotation/freezed_annotation.dart';

part 'enrollment.freezed.dart';
part 'enrollment.g.dart';

@freezed
class CourseRun with _$CourseRun {
  const factory CourseRun({
    required String title,
    @JsonKey(name: 'courseware_id') required String coursewareId,
    @JsonKey(name: 'courseware_url') required String coursewareUrl,
    @JsonKey(name: 'start_date') required String? startDate,
    @JsonKey(name: 'end_date') required String? endDate,
    @JsonKey(name: 'run_tag') required String runTag,
    @JsonKey(name: 'course_number') required String courseNumber,
  }) = _CourseRun;

  factory CourseRun.fromJson(Map<String, dynamic> json) =>
      _$CourseRunFromJson(json);
}

@freezed
class Enrollment with _$Enrollment {
  const factory Enrollment({
    required int id,
    @JsonKey(name: 'enrollment_mode') required String enrollmentMode,
    required CourseRun run,
  }) = _Enrollment;

  factory Enrollment.fromJson(Map<String, dynamic> json) =>
      _$EnrollmentFromJson(json);
}
