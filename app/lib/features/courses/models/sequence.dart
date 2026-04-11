import 'package:freezed_annotation/freezed_annotation.dart';

part 'sequence.freezed.dart';
part 'sequence.g.dart';

@freezed
abstract class SequenceItem with _$SequenceItem {
  const factory SequenceItem({
    required String id,
    required String type,
    required String pageTitle,
    required bool complete,
    required bool bookmarked,
    required String path,
  }) = _SequenceItem;

  factory SequenceItem.fromJson(Map<String, dynamic> json) =>
      _$SequenceItemFromJson(json);
}

@freezed
abstract class SequenceDetail with _$SequenceDetail {
  const factory SequenceDetail({
    required List<SequenceItem> items,
  }) = _SequenceDetail;

  factory SequenceDetail.fromJson(Map<String, dynamic> json) =>
      _$SequenceDetailFromJson(json);
}
