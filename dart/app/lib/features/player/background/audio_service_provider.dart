import 'package:omnilect/features/player/background/lecture_audio_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'audio_service_provider.g.dart';

/// Provides the singleton [LectureAudioHandler] that `audio_service` hands us
/// back from `AudioService.init()`.
///
/// Overridden in `main.dart`'s `ProviderScope` with the real handler built at
/// bootstrap time. This indirection exists so widgets and notifiers can
/// inject the handler for tests without reaching through `AudioService`
/// globals.
@Riverpod(keepAlive: true)
LectureAudioHandler lectureAudioHandler(Ref ref) {
  throw StateError(
    'lectureAudioHandlerProvider must be overridden in the ProviderScope '
    'with the handler returned by AudioService.init() in bootstrap().',
  );
}
