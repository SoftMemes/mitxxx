import 'package:freezed_annotation/freezed_annotation.dart';

part 'xblock_content.freezed.dart';
part 'xblock_content.g.dart';

@freezed
abstract class ParsedVideoBlock with _$ParsedVideoBlock {
  const factory ParsedVideoBlock({
    required String? videoBlockId,
    required String? mp4Url,
    required String? hlsUrl,
    required double duration,
    required Map<String, String> transcriptLanguages,
    required String? transcriptTranslationUrl,
  }) = _ParsedVideoBlock;

  factory ParsedVideoBlock.fromJson(Map<String, dynamic> json) =>
      _$ParsedVideoBlockFromJson(json);
}

@freezed
abstract class XBlockContent with _$XBlockContent {
  const factory XBlockContent({
    required List<ParsedVideoBlock> videos,
    required String htmlContent,
    required bool hasContent,
  }) = _XBlockContent;

  factory XBlockContent.fromJson(Map<String, dynamic> json) =>
      _$XBlockContentFromJson(json);
}
