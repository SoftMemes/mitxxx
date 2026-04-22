import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/features/player/background/lecture_audio_handler.dart';

final _log = Logger('player.audio-session');

/// Wires `audio_session`'s interruption and becoming-noisy streams into the
/// [LectureAudioHandler].
///
/// Owns two subscriptions for the lifetime of the app:
/// - `interruptionEvents`: pauses on interruption begin; resumes when the
///   platform signals the interruption was transient (phone call, Siri) and
///   the user was actively playing when it began.
/// - `becomingNoisyEvents`: pauses when headphones are yanked or a BT device
///   disconnects. The user has to hit play explicitly after this.
///
/// Takes raw streams rather than an `AudioSession` so the wiring can be
/// exercised without a real platform channel.
class AudioSessionController {
  AudioSessionController({
    required Stream<AudioInterruptionEvent> interruptionEvents,
    required Stream<void> becomingNoisyEvents,
    required LectureAudioHandler handler,
  }) : _handler = handler {
    _interruptionSub = interruptionEvents.listen(_onInterruption);
    _becomingNoisySub = becomingNoisyEvents.listen(_onBecomingNoisy);
  }

  /// Convenience constructor for production code — takes an [AudioSession]
  /// and subscribes to its streams.
  AudioSessionController.forSession({
    required AudioSession session,
    required LectureAudioHandler handler,
  }) : this(
          interruptionEvents: session.interruptionEventStream,
          becomingNoisyEvents: session.becomingNoisyEventStream,
          handler: handler,
        );

  final LectureAudioHandler _handler;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;

  /// True when the handler was pausing because of an interruption — used to
  /// decide whether to auto-resume when the interruption ends.
  bool _pausedForInterruption = false;

  Future<void> _onInterruption(AudioInterruptionEvent event) async {
    if (event.begin) {
      final wasPlaying = _handler.playbackState.valueOrNull?.playing ?? false;
      _log.info(
        'interruption begin (type=${event.type}, wasPlaying=$wasPlaying)',
      );
      if (wasPlaying) {
        _pausedForInterruption = true;
        await _handler.pause();
      }
    } else {
      _log.info('interruption end (type=${event.type})');
      // End of interruption. `AudioInterruptionType.pause` means the platform
      // explicitly signalled "you may resume" (iOS `shouldResume`, Android
      // `AUDIOFOCUS_GAIN` after `AUDIOFOCUS_LOSS_TRANSIENT`). Any other type
      // means the loss was permanent / unknown and we stay paused.
      if (_pausedForInterruption &&
          event.type == AudioInterruptionType.pause) {
        _pausedForInterruption = false;
        await _handler.play();
      } else {
        _pausedForInterruption = false;
      }
    }
  }

  Future<void> _onBecomingNoisy(void _) async {
    _log.info('becomingNoisy → pause');
    // Noisy (headphones yanked) always loses any pending auto-resume intent.
    _pausedForInterruption = false;
    await _handler.pause();
  }

  Future<void> dispose() async {
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
  }
}
