import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';

/// `audio_service` [BaseAudioHandler] that adapts the existing
/// [LecturePlaybackController] so lecture audio keeps playing in the
/// background and is controllable from the lock screen / media notification.
///
/// The handler does not own a player of its own. It forwards play/pause/seek
/// to whatever [LecturePlaybackController] is currently [attach]ed, and
/// mirrors that controller's [PlaybackSnapshot] into `audio_service`'s
/// `playbackState` stream.
class LectureAudioHandler extends BaseAudioHandler with SeekHandler {
  static const Duration rewindInterval = Duration(seconds: 10);
  static const Duration fastForwardInterval = Duration(seconds: 30);

  LecturePlaybackController? _controller;
  VoidCallback? _snapshotListener;

  /// The currently-attached controller, if any. Exposed for tests.
  @visibleForTesting
  LecturePlaybackController? get attachedController => _controller;

  /// Attach the current lecture's controller. Called from
  /// `LecturePlayer` (Riverpod notifier) when a lecture opens.
  /// If a previous controller is attached it is detached first, ensuring we
  /// never fan out snapshot updates from a stale controller.
  void attach({
    required LecturePlaybackController controller,
    required MediaItem item,
  }) {
    _detachController();
    _controller = controller;
    mediaItem.add(item);
    void listener() => _emitPlaybackState(controller.snapshot.value);
    _snapshotListener = listener;
    controller.snapshot.addListener(listener);
    _emitPlaybackState(controller.snapshot.value);
  }

  /// Detach the currently-attached controller (if any) without stopping the
  /// audio service itself. The lock-screen session goes idle; a subsequent
  /// [attach] brings it back.
  void detach() {
    _detachController();
    mediaItem.add(null);
    playbackState.add(PlaybackState());
  }

  @override
  Future<void> play() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.snapshot.value.isComplete) {
      await controller.seekGlobal(0);
    }
    await controller.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekGlobal(position.inMilliseconds / 1000.0);
  }

  @override
  Future<void> fastForward() async {
    final controller = _controller;
    if (controller == null) return;
    final snap = controller.snapshot.value;
    final target = (snap.globalPosition + fastForwardInterval.inSeconds)
        .clamp(0.0, snap.totalDuration);
    await controller.seekGlobal(target);
  }

  @override
  Future<void> rewind() async {
    final controller = _controller;
    if (controller == null) return;
    final snap = controller.snapshot.value;
    final target = (snap.globalPosition - rewindInterval.inSeconds)
        .clamp(0.0, snap.totalDuration);
    await controller.seekGlobal(target);
  }

  @override
  Future<void> stop() async {
    await _controller?.pause();
    detach();
    await super.stop();
  }

  void _detachController() {
    final listener = _snapshotListener;
    final controller = _controller;
    if (listener != null && controller != null) {
      controller.snapshot.removeListener(listener);
    }
    _snapshotListener = null;
    _controller = null;
  }

  void _emitPlaybackState(PlaybackSnapshot snap) {
    final position = Duration(
      milliseconds: (snap.globalPosition * 1000).round(),
    );
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        if (snap.isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: snap.error != null
          ? AudioProcessingState.error
          : (snap.isComplete
              ? AudioProcessingState.completed
              : AudioProcessingState.ready),
      playing: snap.isPlaying,
      updatePosition: position,
      bufferedPosition: position,
      speed: _controller?.playbackSpeed ?? 1.0,
      errorMessage: snap.error,
    ));
  }
}
