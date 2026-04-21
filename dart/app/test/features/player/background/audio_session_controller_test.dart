import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/player/background/audio_session_controller.dart';
import 'package:omnilect/features/player/background/lecture_audio_handler.dart';
import 'package:omnilect/features/player/controllers/lecture_playback_controller.dart';

class _SpyController extends LecturePlaybackController {
  _SpyController()
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
  bool _isPlaying = false;

  void setPlaying({required bool playing}) {
    _isPlaying = playing;
    snapshot.value = PlaybackSnapshot(
      globalPosition: 0,
      totalDuration: 100,
      isPlaying: playing,
      activeVideoIndex: 0,
      isComplete: false,
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    setPlaying(playing: true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    setPlaying(playing: false);
  }

  @override
  Future<void> seekGlobal(double globalSeconds) async {}

  @override
  double get totalDuration => 100;

  bool get isPlaying => _isPlaying;

  @override
  void dispose() {
    snapshot.dispose();
  }
}

void main() {
  late LectureAudioHandler handler;
  late _SpyController controller;
  late StreamController<AudioInterruptionEvent> interruptions;
  late StreamController<void> noisy;
  late AudioSessionController sessionController;

  setUp(() {
    handler = LectureAudioHandler();
    controller = _SpyController();
    handler.attach(
      controller: controller,
      item: const MediaItem(id: 'lec-1', title: 'Lecture'),
    );
    interruptions = StreamController<AudioInterruptionEvent>.broadcast();
    noisy = StreamController<void>.broadcast();
    sessionController = AudioSessionController(
      interruptionEvents: interruptions.stream,
      becomingNoisyEvents: noisy.stream,
      handler: handler,
    );
  });

  tearDown(() async {
    await sessionController.dispose();
    await interruptions.close();
    await noisy.close();
    controller.dispose();
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('interruption begin while playing → pause', () async {
    await controller.play();
    expect(handler.playbackState.value.playing, isTrue);

    interruptions
        .add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await flush();

    expect(controller.pauseCalls, 1);
    expect(controller.isPlaying, isFalse);
  });

  test('interruption begin while paused → no-op', () async {
    // Handler never played → no pause call on interruption begin.
    interruptions
        .add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await flush();
    expect(controller.pauseCalls, 0);
  });

  test('interruption end with type pause → auto-resume', () async {
    await controller.play();
    interruptions
        .add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await flush();
    expect(controller.isPlaying, isFalse);

    interruptions
        .add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await flush();
    expect(controller.playCalls, 2); // initial + auto-resume
    expect(controller.isPlaying, isTrue);
  });

  test('interruption end with type unknown → stays paused', () async {
    await controller.play();
    interruptions
        .add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
    await flush();

    interruptions
        .add(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
    await flush();
    expect(controller.playCalls, 1); // only the initial play
    expect(controller.isPlaying, isFalse);
  });

  test('becomingNoisy while playing → pause and no auto-resume', () async {
    await controller.play();
    noisy.add(null);
    await flush();

    expect(controller.pauseCalls, 1);
    expect(controller.isPlaying, isFalse);

    // Subsequent interruption end of type pause must not resume, because
    // noisy cleared the auto-resume flag.
    interruptions
        .add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
    await flush();
    expect(controller.playCalls, 1);
  });
}
