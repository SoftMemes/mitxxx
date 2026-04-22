import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';

/// Activates / deactivates the shared audio session. Injected so tests can
/// observe activation without going through the real platform channel.
typedef AudioSessionActivator = Future<bool> Function({required bool active});

Future<bool> _defaultActivator({required bool active}) async {
  final session = await AudioSession.instance;
  return session.setActive(active);
}

/// `audio_service` [BaseAudioHandler] that adapts the existing
/// [LecturePlaybackController] so lecture audio keeps playing in the
/// background and is controllable from the lock screen / media notification.
///
/// The handler does not own a player of its own. It forwards play/pause/seek
/// to whatever [LecturePlaybackController] is currently [attach]ed, and
/// mirrors that controller's [PlaybackSnapshot] into `audio_service`'s
/// `playbackState` stream.
///
/// On [play] / [pause] / [stop] the handler activates / deactivates the
/// shared [AudioSession]. `video_player` does not route through
/// `audio_session`, so without this bracket the interruption stream stays
/// silent on Android and iOS's session activation is left to AVPlayer's
/// implicit behaviour (unreliable in the simulator).
class LectureAudioHandler extends BaseAudioHandler with SeekHandler {
  LectureAudioHandler({AudioSessionActivator? activator})
      : _activator = activator ?? _defaultActivator;

  static const Duration rewindInterval = Duration(seconds: 10);
  static const Duration fastForwardInterval = Duration(seconds: 30);

  final AudioSessionActivator _activator;

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
    // Claim audio focus / activate the AVAudioSession before touching the
    // player. If the platform denies focus (e.g. another app is mid-call on
    // Android), stay paused.
    if (!await _activator(active: true)) return;
    if (controller.snapshot.value.isComplete) {
      await controller.seekGlobal(0);
    }
    await controller.play();
  }

  @override
  Future<void> pause() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    // Release focus so other apps can take over while we're paused; the next
    // play() re-requests it.
    await _activator(active: false);
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
    await _activator(active: false);
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
