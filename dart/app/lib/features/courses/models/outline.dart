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

/// Lightweight representation of a sequence from the outline API.
/// Used to show real sequence titles instead of "Part N".
@freezed
abstract class SequenceInfo with _$SequenceInfo {
  const factory SequenceInfo({
    required String id,
    required String title,
  }) = _SequenceInfo;

  factory SequenceInfo.fromJson(Map<String, dynamic> json) =>
      _$SequenceInfoFromJson(json);
}

@freezed
abstract class OutlineData with _$OutlineData {
  const factory OutlineData({
    required List<Section> sections,
    /// Map from sequence block ID to sequence info (titles etc.).
    /// Populated from the `sequences` dict in the LMS outline response.
    @Default({}) Map<String, SequenceInfo> sequences,
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
