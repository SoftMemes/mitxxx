// ignore_for_file: uri_has_not_been_generated
import 'package:freezed_annotation/freezed_annotation.dart';

part 'vertical_segment.freezed.dart';

/// One vertical (sub-part of a lecture sequence) as seen by the lecture player.
///
/// [videoUrl] is null for verticals that have no video content.
/// [videoDuration] is 0 when there is no video.
/// [globalStartTime] is the offset (in seconds) at which this segment's video
/// begins in the stitched playback timeline. For segments with no video this
/// is set to the start time of the nearest preceding video segment (or 0 if
/// none precedes it) — it is only used for the play-button seek target.
/// [safeHtmlContent] has already been sanitized (scripts/iframes/problems
/// stripped). May be empty.
@freezed
abstract class VerticalSegment with _$VerticalSegment {
  const factory VerticalSegment({
    required String verticalId,
    required String title,
    required Uri? videoUrl,
    required double videoDuration,
    required double globalStartTime,
    required String safeHtmlContent,
  }) = _VerticalSegment;
}
