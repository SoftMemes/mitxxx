import 'package:freezed_annotation/freezed_annotation.dart';

part 'outline.freezed.dart';
part 'outline.g.dart';

@freezed
class Section with _$Section {
  const factory Section({
    required String id,
    required String title,
    @JsonKey(name: 'sequence_ids') required List<String> sequenceIds,
    required String? start,
    @JsonKey(name: 'effective_start') required String? effectiveStart,
  }) = _Section;

  factory Section.fromJson(Map<String, dynamic> json) =>
      _$SectionFromJson(json);
}

@freezed
class OutlineData with _$OutlineData {
  const factory OutlineData({
    required List<Section> sections,
  }) = _OutlineData;

  factory OutlineData.fromJson(Map<String, dynamic> json) =>
      _$OutlineDataFromJson(json);
}

@freezed
class CourseOutline with _$CourseOutline {
  const factory CourseOutline({
    @JsonKey(name: 'course_key') required String courseKey,
    required String title,
    @JsonKey(name: 'course_start') required String? courseStart,
    @JsonKey(name: 'course_end') required String? courseEnd,
    required OutlineData outline,
  }) = _CourseOutline;

  factory CourseOutline.fromJson(Map<String, dynamic> json) =>
      _$CourseOutlineFromJson(json);
}
