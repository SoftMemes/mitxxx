import 'package:freezed_annotation/freezed_annotation.dart';

part 'sequence.freezed.dart';
part 'sequence.g.dart';

@freezed
abstract class SequenceItem with _$SequenceItem {
  const factory SequenceItem({
    required String id,
    required String type,
    required String pageTitle,
    required String path,
    // `complete` was dropped from the LMS sequence response; `bookmarked` can
    // also be absent on unauthenticated/limited responses. Default both to
    // `false` rather than crashing fromJson with a "null is not a subtype of
    // bool" cast on the lecture screen.
    @Default(false) bool complete,
    @Default(false) bool bookmarked,
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
