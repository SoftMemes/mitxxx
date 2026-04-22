import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/player/background/lecture_audio_handler.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';

class _FakeController extends LecturePlaybackController {
  _FakeController()
      : super([
          VideoScheduleEntry(
            segmentIndex: 0,
            uri: Uri.parse('file:///dev/null'),
            duration: 100,
            globalStartTime: 0,
          ),
        ]);

  int playCalls = 0;
  int pauseCalls = 0;
  final List<double> seekCalls = [];

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> seekGlobal(double globalSeconds) async {
    seekCalls.add(globalSeconds);
  }

  @override
  double get totalDuration => 100;

  /// Push a new snapshot through the listener pipeline.
  PlaybackSnapshot get currentSnapshot => snapshot.value;
  set currentSnapshot(PlaybackSnapshot value) => snapshot.value = value;

  @override
  void dispose() {
    // Skip the super impl: we never attached a real video_player controller.
    snapshot.dispose();
  }
}

const _item = MediaItem(id: 'lec-1', title: 'Lecture 1', album: 'Course X');

PlaybackSnapshot _snap({
  double pos = 0,
  double dur = 100,
  bool playing = false,
  bool complete = false,
  String? error,
}) =>
    PlaybackSnapshot(
      globalPosition: pos,
      totalDuration: dur,
      isPlaying: playing,
      activeVideoIndex: 0,
      isComplete: complete,
      error: error,
    );

class _FakeActivator {
  final List<bool> calls = [];
  bool nextResult = true;

  Future<bool> call({required bool active}) async {
    calls.add(active);
    return nextResult;
  }
}

void main() {
  late LectureAudioHandler handler;
  late _FakeController controller;
  late _FakeActivator activator;

  setUp(() {
    activator = _FakeActivator();
    handler = LectureAudioHandler(activator: activator.call);
    controller = _FakeController();
  });

  tearDown(() {
    controller.dispose();
  });

  test('attach emits initial playbackState from the controller snapshot', () {
    controller.currentSnapshot = _snap(pos: 12, playing: true);
    handler.attach(controller: controller, item: _item);

    final state = handler.playbackState.value;
    expect(state.playing, isTrue);
    expect(state.updatePosition.inSeconds, 12);
    expect(state.processingState, AudioProcessingState.ready);
    expect(handler.mediaItem.value, _item);
  });

  test('snapshot updates propagate to playbackState', () {
    handler.attach(controller: controller, item: _item);
    expect(handler.playbackState.value.playing, isFalse);

    controller.currentSnapshot = _snap(pos: 30, playing: true);
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.updatePosition.inSeconds, 30);

    controller.currentSnapshot = _snap(pos: 30);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('isComplete snapshot emits completed processingState', () {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(pos: 100, complete: true);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.completed,
    );
  });

  test('error snapshot emits error processingState with message', () {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(error: 'boom');
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.error,
    );
    expect(handler.playbackState.value.errorMessage, 'boom');
  });

  test('attaching a new controller unsubscribes from the old one', () {
    handler.attach(controller: controller, item: _item);
    final newController = _FakeController();
    addTearDown(newController.dispose);

    handler.attach(controller: newController, item: _item);
    // The old controller's updates must not leak into playbackState anymore.
    controller.currentSnapshot = _snap(pos: 77, playing: true);
    expect(handler.playbackState.value.updatePosition.inSeconds, isNot(77));
    expect(handler.playbackState.value.playing, isFalse);

    newController.currentSnapshot = _snap(pos: 5, playing: true);
    expect(handler.playbackState.value.updatePosition.inSeconds, 5);
  });

  test('detach clears mediaItem and resets playbackState', () {
    handler
      ..attach(controller: controller, item: _item)
      ..detach();
    expect(handler.mediaItem.value, isNull);
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );

    // Subsequent controller updates must not leak after detach.
    controller.currentSnapshot = _snap(pos: 99, playing: true);
    expect(handler.playbackState.value.updatePosition.inSeconds, isNot(99));
  });

  test('play / pause / seek delegate to the attached controller', () async {
    handler.attach(controller: controller, item: _item);
    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(seconds: 42));

    expect(controller.playCalls, 1);
    expect(controller.pauseCalls, 1);
    expect(controller.seekCalls, [42.0]);
  });

  test('play() from a completed snapshot seeks to 0 first', () async {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(pos: 100, complete: true);
    await handler.play();

    expect(controller.seekCalls, [0.0]);
    expect(controller.playCalls, 1);
  });

  test('fastForward seeks +30 and clamps to totalDuration', () async {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(pos: 50);
    await handler.fastForward();
    expect(controller.seekCalls.last, 80.0);

    controller.currentSnapshot = _snap(pos: 90);
    await handler.fastForward();
    // 90 + 30 = 120, clamped to totalDuration 100.
    expect(controller.seekCalls.last, 100.0);
  });

  test('rewind seeks -10 and clamps to 0', () async {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(pos: 25);
    await handler.rewind();
    expect(controller.seekCalls.last, 15.0);

    controller.currentSnapshot = _snap(pos: 5);
    await handler.rewind();
    expect(controller.seekCalls.last, 0.0);
  });

  test('delegating commands with no attached controller is a no-op', () async {
    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(seconds: 1));
    await handler.fastForward();
    await handler.rewind();
    // Doesn't throw, doesn't emit a playbackState with bogus values.
    expect(handler.playbackState.value.playing, isFalse);
    // No attached controller → no reason to touch the audio session.
    expect(activator.calls, isEmpty);
  });

  test('play activates the audio session before calling the controller',
      () async {
    handler.attach(controller: controller, item: _item);
    await handler.play();

    expect(activator.calls, [true]);
    expect(controller.playCalls, 1);
  });

  test('play stays paused when the platform denies audio focus', () async {
    handler.attach(controller: controller, item: _item);
    activator.nextResult = false;

    await handler.play();

    expect(activator.calls, [true]);
    expect(controller.playCalls, 0);
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('pause deactivates the audio session after pausing the controller',
      () async {
    handler.attach(controller: controller, item: _item);
    await handler.pause();

    expect(controller.pauseCalls, 1);
    expect(activator.calls, [false]);
  });

  test('stop deactivates the audio session', () async {
    handler.attach(controller: controller, item: _item);
    await handler.stop();

    expect(controller.pauseCalls, 1);
    expect(activator.calls, contains(false));
    expect(handler.mediaItem.value, isNull);
  });

  test('seek / fastForward / rewind do not touch the audio session', () async {
    handler.attach(controller: controller, item: _item);
    controller.currentSnapshot = _snap(pos: 50);

    await handler.seek(const Duration(seconds: 10));
    await handler.fastForward();
    await handler.rewind();

    expect(activator.calls, isEmpty);
  });
}
