// ignore_for_file: uri_has_not_been_generated
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:omnilect/features/player/models/vertical_segment.dart';

part 'lecture_player_state.freezed.dart';

/// Runtime state for the single-page lecture player.
///
/// This is the state published by `LecturePlayer` and consumed by the UI.
/// It is never persisted to disk.
@freezed
abstract class LecturePlayerState with _$LecturePlayerState {
  const factory LecturePlayerState({
    /// All verticals in this sequence, in order.
    required List<VerticalSegment> segments,

    /// Index into [segments] of the currently expanded section.
    @Default(0) int activeSegmentIndex,

    /// Current playback position across the stitched timeline (seconds).
    @Default(0.0) double globalPosition,

    /// Whether the video is currently playing.
    @Default(false) bool isPlaying,

    /// True when the user has manually expanded a section while the video was
    /// playing. Auto-sync is suspended until the video crosses the next segment
    /// boundary, at which point this is cleared.
    @Default(false) bool userOverrideActive,

    /// True once the last video segment has finished playing.
    @Default(false) bool isComplete,

    /// Non-null when a segment has failed to load. Cleared on retry.
    String? errorMessage,
  }) = _LecturePlayerState;
}
