import 'package:freezed_annotation/freezed_annotation.dart';

part 'outline.freezed.dart';
part 'outline.g.dart';

@freezed
abstract class Section with _$Section {
  const factory Section({
    required String id,
    required String title,
    required List<String> sequenceIds,
    required String? start,
    required String? effectiveStart,
  }) = _Section;

  factory Section.fromJson(Map<String, dynamic> json) =>
      _$SectionFromJson(json);
}

@freezed
abstract class OutlineData with _$OutlineData {
  const factory OutlineData({
    required List<Section> sections,
  }) = _OutlineData;

  factory OutlineData.fromJson(Map<String, dynamic> json) =>
      _$OutlineDataFromJson(json);
}

@freezed
abstract class CourseOutline with _$CourseOutline {
  const factory CourseOutline({
    required String courseKey,
    required String title,
    required String? courseStart,
    required String? courseEnd,
    required OutlineData outline,
  }) = _CourseOutline;

  factory CourseOutline.fromJson(Map<String, dynamic> json) =>
      _$CourseOutlineFromJson(json);
}
