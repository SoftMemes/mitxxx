# Video Background Mode Specification

> **Version**: 1.0 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-21

## Overview / Goals

Currently when the app is backgrounded or the screen is locked, lecture video
playback stops. This spec makes lecture audio continue playing in the
background — position advances, segments auto-advance across boundaries,
and progress tracking keeps recording — so the user can listen to lectures
with the phone locked or while using other apps. System lock-screen /
Control Center / notification controls let the user pause, play, skip, and
scrub without returning to the app.

### Goals

- Audio continues when the app is backgrounded or the screen is locked.
- Segment auto-advance continues across boundaries in the background.
- Lock-screen / Control Center (iOS) and media notification (Android)
  controls let the user pause/play/skip/scrub and show course + lecture
  metadata.
- Audio-focus interactions (phone calls, Siri, other media apps, earbud
  disconnect) behave like a well-mannered media player.
- Progress tracking keeps working in the background.
- Returning to the app shows the correct playback state with no visible
  "resync" needed.

### Non-goals

- No video rendering in the background — only audio continues (standard
  behaviour on both platforms; the decoded video track is paused by the OS
  and resumes on foreground).
- No sleep timer, no cross-app media handoff (AirPlay handoff), no
  CarPlay / Android Auto integration.
- No user setting to disable background playback (v1 behaviour is always on
  for the lecture player).

## Scope

### In scope

- The stitched MITx lecture player (`LecturePlaybackController` /
  `LectureVideoPlayer` under `dart/app/lib/features/player/`).
- OCW single-video lectures. OCW already flows through
  `LecturePlayerProvider` as a one-segment schedule on top of the same
  `LecturePlaybackController` (see `_buildOcw` in
  `lecture_player_provider.dart`), so the same handler/adapter covers it
  with no platform branching — the only differences are in how the
  `MediaItem` is built (OCW `lectureId` is `ocw:<slug>/<lecture-slug>`,
  course title comes from the OCW course model, thumbnail is the OCW
  course's cached thumbnail).
- Both streamed (CDN) and downloaded (local `file://`) lecture segments.
- Segment auto-advance across boundaries while backgrounded (pre-init of
  the next segment continues to work because the `VideoPlayerController`
  instance remains alive while iOS keeps the audio session active and
  Android holds the foreground service). For OCW the schedule is a
  single segment, so there's no cross-boundary advance — but the same
  code path applies.
- Progress tracking updates (`ProgressTracker`) continue to fire from the
  `LecturePlaybackController` snapshot listener while backgrounded. The
  existing OCW canonical-lecture-id handling (`$courseId/$sequenceId`)
  in the provider is unchanged.

### Out of scope (v1)

- Picture-in-Picture (PiP). Separate concern, separate permissions.
- Background playback during an active Chromecast / AirPlay cast session
  (the cast receiver plays the audio, not the phone — see "Interaction
  with Other Features").

## User Experience

### Happy path

1. User starts playing a lecture in the MITx lecture screen.
2. User presses the side button / swipes home / switches apps.
3. Audio keeps playing. Segment boundaries are crossed seamlessly — the
   next-segment pre-init that runs at 80% continues to work because the
   controller is still alive.
4. On iOS, the lock screen shows the current lecture title, course name,
   course thumbnail if available, and play/pause + skip ± controls.
5. On Android, a media-style notification in the "Playback" channel shows
   the same, with tap-to-return-to-app behaviour.
6. User unlocks the phone / returns to the app — the `LectureVideoPlayer`
   widget rebuilds against the live `PlaybackSnapshot` and shows the
   correct position immediately (no spinner, no reseek).

### Audio interruption

- Phone call, Siri, another media app taking audio focus → the player
  pauses. `_wantPlaying` is cleared so auto-advance is also paused.
- When the interruption ends, the player **resumes automatically** if the
  interruption was transient (iOS `AVAudioSessionInterruptionOptionShouldResume`,
  Android `AUDIOFOCUS_GAIN` after `AUDIOFOCUS_LOSS_TRANSIENT`).
- If the user actively pressed play on another media app, we treat that as
  a permanent focus loss (`AUDIOFOCUS_LOSS`) and stay paused.
- No ducking. Lecture audio is speech-heavy and mixing with other audio is
  unhelpful.

### Earbud / Bluetooth disconnect

- On headphones-unplugged / Bluetooth-disconnect (iOS
  `AVAudioSessionRouteChangeReasonOldDeviceUnavailable`, Android
  `ACTION_AUDIO_BECOMING_NOISY`), pause playback. This matches standard
  platform behaviour — users expect that yanking earbuds does not start
  blasting audio from the speaker.

### Lock-screen / notification controls

Supported commands (iOS `MPRemoteCommandCenter` + Android `MediaSession`):

| Command | Behaviour |
|---|---|
| Play | `controller.play()` |
| Pause | `controller.pause()` |
| Skip backward 10s | `controller.seekGlobal(globalPosition - 10)` |
| Skip forward 30s | `controller.seekGlobal(globalPosition + 30)` |
| Scrub / seek to position | `controller.seekGlobal(targetSeconds)` |

The skip intervals match the in-app overlay (10s back, 30s forward) so
lock-screen behaviour is consistent with tap behaviour.

Next / previous track commands are **not** exposed. The stitched lecture
is modelled as a single media item; "previous lecture" / "next lecture" is
not meaningful to expose at the lock-screen level in v1.

### Now-playing metadata

- **Title**: the current sequence (lecture) title. For OCW, the OCW
  lecture title resolved in `_buildOcw`.
- **Artist / subtitle**: the course title (e.g. "24.09x — Minds and
  Machines"). For OCW, the OCW course title.
- **Album art / artwork**: the course thumbnail (the same asset shown in
  the course list). OCW thumbnails come from the OCW course model —
  `file://` URI if cached on disk, CDN URL otherwise. If no thumbnail is
  available, fall back to the app icon. The artwork does **not** change
  per vertical — the lecture is one media item.
- **Duration**: `snapshot.totalDuration` (full stitched lecture duration
  for MITx; single-segment duration for OCW).
- **Elapsed time**: `snapshot.globalPosition`. Updated on every snapshot
  tick; the media session `playbackState` also updates so Control Center's
  progress bar animates smoothly.

The `MediaItem` is built in `media_item_builder.dart` and dispatches on
`courseId.startsWith('ocw:')` to pick the right source (MITx course +
sequence vs. OCW course + lecture).

## Architecture & Design

### Package choice

Add two packages; keep `video_player` + `chewie` as-is.

- **`audio_session: ^0.1.x`** — lightweight wrapper over iOS
  `AVAudioSession` and Android `AudioManager`/`AudioFocusRequest`. Used
  once at app startup to configure the category (`playback`) and to listen
  for interruption + becomingNoisy events.
- **`audio_service: ^0.18.x`** — provides the platform plumbing for
  lock-screen artwork, notification, and remote commands, and owns the
  Android foreground service. We do **not** use its `just_audio` pairing;
  instead we implement `BaseAudioHandler` as a **thin adapter** over the
  existing `LecturePlaybackController`, delegating play/pause/seek to it
  and pushing its `PlaybackSnapshot` stream into `audio_service`'s
  `playbackState` + `mediaItem` streams.

### Why not migrate to `just_audio`

The stitched lecture player is tightly coupled to `video_player` — it owns
segment pre-init, preload, seek-serialization, and casting integration
(see `LecturePlaybackController`, ~500 lines). A `just_audio` migration
would require rebuilding all of that for audio-only + a parallel
video-only pipeline for the in-app rendered view. Wrapping the existing
controller with `audio_service` is a materially smaller change with the
same user-visible outcome.

### Component layout

```
lib/features/player/
  background/
    lecture_audio_handler.dart       # BaseAudioHandler adapter
    audio_session_controller.dart    # audio_session config + interruption wiring
    media_item_builder.dart          # builds MediaItem from course + lecture
  controllers/
    lecture_playback_controller.dart # unchanged; source of truth
  widgets/
    lecture_video_player.dart        # unchanged
  providers/
    lecture_player_provider.dart     # wires handler to controller on init
main.dart                            # AudioService.init(...) at bootstrap
```

### `LectureAudioHandler`

```dart
class LectureAudioHandler extends BaseAudioHandler with SeekHandler {
  LectureAudioHandler();

  LecturePlaybackController? _controller;
  VoidCallback? _snapshotListener;

  /// Attach the current lecture's controller. Called from
  /// `LecturePlayerProvider` when a lecture opens. If a previous
  /// controller is attached it is detached first.
  void attach({
    required LecturePlaybackController controller,
    required MediaItem item,
  }) {
    _detach();
    _controller = controller;
    mediaItem.add(item);
    _snapshotListener = () => _emitPlaybackState(controller.snapshot.value);
    controller.snapshot.addListener(_snapshotListener!);
    _emitPlaybackState(controller.snapshot.value);
  }

  void _detach() {
    if (_snapshotListener != null && _controller != null) {
      _controller!.snapshot.removeListener(_snapshotListener!);
    }
    _snapshotListener = null;
    _controller = null;
    playbackState.add(PlaybackState(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    mediaItem.add(null);
  }

  @override Future<void> play()  async => _controller?.play();
  @override Future<void> pause() async => _controller?.pause();
  @override Future<void> seek(Duration pos) async =>
      _controller?.seekGlobal(pos.inMilliseconds / 1000.0);
  @override Future<void> stop() async {
    await _controller?.pause();
    _detach();
    await super.stop();
  }
  @override Future<void> fastForward() async {
    final snap = _controller?.snapshot.value;
    if (snap == null) return;
    await _controller!.seekGlobal(
      (snap.globalPosition + 30).clamp(0, snap.totalDuration),
    );
  }
  @override Future<void> rewind() async {
    final snap = _controller?.snapshot.value;
    if (snap == null) return;
    await _controller!.seekGlobal(
      (snap.globalPosition - 10).clamp(0, snap.totalDuration),
    );
  }

  void _emitPlaybackState(PlaybackSnapshot snap) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.rewind,
        snap.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: snap.error != null
          ? AudioProcessingState.error
          : AudioProcessingState.ready,
      playing: snap.isPlaying,
      updatePosition: Duration(
        milliseconds: (snap.globalPosition * 1000).round(),
      ),
      bufferedPosition: Duration(
        milliseconds: (snap.globalPosition * 1000).round(),
      ),
      speed: _controller?.playbackSpeed ?? 1.0,
    ));
  }
}
```

### Wiring into `LecturePlayerProvider`

The existing provider (created by the progress-tracking work) already owns
the `LecturePlaybackController` lifecycle for the current lecture. When a
lecture is loaded:

1. Build a `MediaItem` (id = sequenceId, title = lecture title,
   album = course title, artUri = course thumbnail URL or local asset
   URI, duration = stitched totalDuration).
2. Call `lectureAudioHandler.attach(controller: ..., item: item)`.
3. On provider dispose / lecture switch, call
   `lectureAudioHandler.stop()` which in turn calls `_detach()`.

### App startup

`main.dart` (both `main_dev.dart` and `main_prod.dart` via `bootstrap`)
adds:

```dart
final lectureAudioHandler = await AudioService.init(
  builder: () => LectureAudioHandler(),
  config: const AudioServiceConfig(
    androidNotificationChannelId: 'app.omnilect.lecture_audio',
    androidNotificationChannelName: 'Lecture playback',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    androidNotificationIcon: 'mipmap/ic_launcher',
    preloadArtwork: true,
  ),
);

// Configure audio session category once.
final session = await AudioSession.instance;
await session.configure(const AudioSessionConfiguration.speech());

// Subscribe to interruption + noisy events; translate into
// controller.pause() / controller.play() as appropriate.
AudioSessionController.instance.bind(lectureAudioHandler);
```

`AudioSessionController` wraps the `session.interruptionEventStream` and
`session.becomingNoisyEventStream` and calls into
`lectureAudioHandler.pause()` / `play()`.

### Audio session configuration

Use `AudioSessionConfiguration.speech()` which maps to:

- **iOS**: category `playback`, mode `spokenAudio`, options
  `mixWithOthers: false`, `duckOthers: false`. Category `playback` is what
  tells iOS that this audio is primary and should continue when locked or
  backgrounded.
- **Android**: stream type `music`, focus gain
  `AUDIOFOCUS_GAIN`, content type `CONTENT_TYPE_SPEECH`, usage
  `USAGE_MEDIA`, no pause-on-duck (the `audio_session` speech preset
  treats transient loss as "pause then resume" rather than duck).

## Platform Specifics

### iOS

**`dart/app/ios/Runner/Info.plist`**

Already has (added for casting):

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>fetch</string>
</array>
```

No further Info.plist changes required. The `audio_service` plugin wires
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` internally.

Artwork is fetched from the course thumbnail URL via `audio_service`'s
`MediaItem.artUri`. For downloaded courses without network, the artwork
URL falls back to a locally-bundled asset (`assets/icons/app_icon.png`)
by resolving at `attach()` time — if the course's cached thumbnail exists
on disk, use a `file://` URI; otherwise use the bundled asset.

Minimum iOS version unchanged (14.0 — bumped earlier for casting).

### Android

**`dart/app/android/app/src/main/AndroidManifest.xml`**

Already has:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
```

Needs to be added:

- `MainActivity.kt` must extend `com.ryanheise.audioservice.AudioServiceActivity`
  rather than the default `io.flutter.embedding.android.FlutterActivity`.
  Without this, `AudioService.init()` throws "The Activity class declared
  in your AndroidManifest.xml is wrong or has not provided the correct
  FlutterEngine" on launch.
- `AndroidManifest.xml` must declare the plugin's `<service>` and
  `<receiver>` inside `<application>` (the plugin does not auto-merge
  them). Without these, `AudioService.init()` throws "Unable to bind to
  AudioService". The service needs
  `android:foregroundServiceType="mediaPlayback"` for Android 14+.
  The receiver handles hardware media-button intents. Reference snippet
  lives in the audio_service README.
- Target SDK: unchanged. The `POST_NOTIFICATIONS` permission is already
  declared — on Android 13+ the system will auto-prompt the first time
  the foreground service posts its notification, which is acceptable.

Notification channel:

- Channel id: `app.omnilect.lecture_audio`
- Channel name: "Lecture playback"
- Created by `audio_service` via `AudioServiceConfig`.

Android 14 foreground service type requirement is satisfied by the
`mediaPlayback` type set by `audio_service`.

### Flavor nuance

Both `main_dev.dart` and `main_prod.dart` call `bootstrap()`. The
`AudioService.init()` call lives inside `bootstrap()` so both flavors get
it. The notification channel id is identical across flavors — acceptable,
since only one flavor can be installed with the same application id at a
time on a device.

## Interaction with Other Features

### Casting (Chromecast / AirPlay)

- When a cast session becomes `connected`, `LecturePlayerProvider`
  currently swaps in `CastControllerPanel` and the local
  `LecturePlaybackController` is detached / disposed. At this point the
  audio session should be **deactivated** and the `LectureAudioHandler`
  should call `stop()` so the lock-screen controls disappear — the cast
  receiver (TV / speaker) is now the renderer and the phone is just a
  remote control.
- On cast disconnect, the local player is re-created (paused at last
  known position per the existing casting spec). The handler re-attaches
  and lock-screen controls reappear.

### Downloads

No interaction. `background_downloader` manages its own notification /
foreground service independently; it coexists with the `audio_service`
one. Downloads can continue to progress while background audio plays.

### Progress tracking

Progress tracking hooks on the `PlaybackSnapshot` listener in
`LecturePlayerProvider`. Because the Dart isolate keeps running on iOS
for as long as the audio session is active, and keeps running on Android
for as long as the foreground service runs, `ProgressTracker.recordPosition`
and the 5s-throttled persists continue to happen normally in the
background. No change required in the progress-tracking layer.

Explicit callout: `progressTracker.flushPosition` on app-backgrounded (as
described in the progress-tracking spec) is still called from the
`AppLifecycleState.paused` handler — it's fine to flush even though the
player isn't actually pausing, so the DB stays fresh if the OS later
kills the app while it's backgrounded-but-playing.

### Settings / user control

No user-visible setting in v1. Background playback is on by default for
the lecture player. If future telemetry shows user complaints (battery
draw, unexpected keeps-playing after task-switch), a toggle can be added
under Settings. Out of scope now.

## Edge Cases & Error Handling

| Scenario | Behaviour |
|---|---|
| Phone call incoming while playing | Audio session interruption → `handler.pause()`. On call end and `shouldResume == true`, `handler.play()`. |
| Siri activated | Same as phone call (transient interruption). |
| Another media app starts (Spotify play) | Permanent focus loss → `handler.pause()`; stay paused. |
| Earbuds unplugged / BT disconnect | `becomingNoisy` event → `handler.pause()`. User must explicitly resume. |
| Segment fails to load in background | Existing error surface on `PlaybackSnapshot.error` applies. Playback pauses; lock-screen controls show play icon. No toast (we're in the background) — user will see the error banner on return. |
| OS kills the app while backgrounded | The foreground service / audio session is released; audio stops. Progress was flushed on `AppLifecycleState.paused`, so a cold start reopens the course outline with Continue pointing at the last flushed position. No auto-resume from background-kill — user taps Continue. |
| Reached end of lecture in background | `LecturePlaybackController._advanceToNext` hits end-of-schedule, sets `isComplete: true`, pauses. Handler emits `processingState: completed`, lock-screen shows play as replay. **No auto-advance to next lecture in v1** — matches current in-app behaviour (the lecture screen shows a "Lecture complete" UI; advancing across lectures is a user-initiated action). |
| User hits play on lock screen after completion | Seeks to 0 (or near 0) via `seekGlobal(0)` and plays. Handled by the default replay behaviour of `BaseAudioHandler` + the seek-to-0 we add in `play()` when snapshot `isComplete == true`. |
| Lecture switched while another is attached | `handler.attach()` first calls `_detach()` on the old controller, ensuring we never fan out snapshot updates from a stale controller. |
| Background auto-advance preload fails | Same as foreground: `_preloadNextSegment` swallows failure; when the boundary is reached, `_loadSegment` runs inline; if *that* also fails, the snapshot gets an `error` and we pause. |
| App is backgrounded with the video paused | No audio session activation is needed. Handler emits paused state; no foreground service on Android (`androidStopForegroundOnPause: true`). Resuming play re-activates. |
| Audio route changes (AirPods → Speaker) | Treat as `becomingNoisy` only when the previous route was "headphones-ish" and the new route is the speaker. Let `audio_session`'s default heuristics handle this — no custom logic. |

## Testing Strategy

Unit + manual. No widget/integration tests for this surface — the
platform plumbing is hard to exercise in a Flutter test harness.

### Unit tests

- `test/features/player/background/lecture_audio_handler_test.dart`
  - `attach()` emits a `playbackState` with `playing: false` when the
    controller is in initial state.
  - `attach()` then controller snapshot update with `isPlaying: true`
    emits `playbackState.playing == true`.
  - `play()` / `pause()` / `seek()` delegate to the controller.
  - `fastForward()` clamps to `totalDuration`; `rewind()` clamps to 0.
  - `attach()` with a second controller first detaches the first
    (previous listener is unsubscribed — verify via a counter).
  - `stop()` emits `idle` + clears `mediaItem`.
- `test/features/player/background/audio_session_controller_test.dart`
  - Interruption `begin` → `handler.pause()` called.
  - Interruption `end` with `shouldResume: true` → `handler.play()`.
  - Interruption `end` with `shouldResume: false` → no `play()`.
  - `becomingNoisy` event → `handler.pause()`.

### Manual QA checklist

On a physical iPhone and a physical Android device, run the checklist
below once with an MITx lecture and once with an OCW lecture (step 4 is
MITx-only since OCW is single-segment):

1. Start a lecture playing, press side button. Verify audio keeps
   playing. Verify lock-screen artwork, title, course, duration, and
   progress bar updates.
2. Pause from lock screen — verify audio stops and in-app UI reflects the
   pause on return.
3. Skip forward 30s, skip back 10s, and scrub from lock screen — verify
   position updates correctly and does not re-seek past segment
   boundaries incorrectly.
4. Cross a segment boundary while backgrounded. Verify the next segment
   auto-plays without a gap, and that the lock-screen metadata stays on
   the same lecture title / artwork.
5. Trigger an incoming phone call mid-playback. Verify pause. End the
   call. Verify auto-resume.
6. Play audio, open Spotify, press Spotify play. Verify lecture pauses
   and stays paused.
7. Unplug wired earbuds / disconnect Bluetooth headphones. Verify
   immediate pause.
8. Lock the phone for 10 minutes of continuous playback. Verify position
   continues to advance and audio still plays.
9. Cast to a Chromecast, then background the app. Verify the lock-screen
   now-playing UI does **not** show a local-playback session (cast is
   driving the audio on the TV).
10. Disconnect cast; lock phone; verify local audio resumes from the
    restored paused position when the user presses play on the lock
    screen.
11. Kill the app from the background while playing. Reopen. Verify
    Continue tile shows the correct last-played position.
12. Downloads + background audio: start a download, start a lecture,
    background the app. Verify both the download notification and the
    lecture media notification appear, and neither interferes with the
    other.

### Acceptance criteria

- Criteria 1, 4, 8 above are the "done" bar — if those work on both iOS
  and Android, the feature ships.

## Rollout Plan

Single-phase rollout with the rest of the app (no feature flag). The
change is mostly additive:

- New packages (`audio_session`, `audio_service`) added to `pubspec.yaml`.
- New files under `lib/features/player/background/`.
- Small init addition in `bootstrap()`.
- Attach/detach hook in the existing `LecturePlayerProvider`.
- Detach hook on cast session becoming connected (in cast controller).

If issues are reported post-release, the follow-up is to add a
Settings toggle ("Continue audio in background" — default on). Not in
v1.

### Follow-ups (explicitly out of v1)

- Sleep timer.
- CarPlay / Android Auto.
- PiP.

## Key Files / Packages Reference

### New packages (`pubspec.yaml`)

- `audio_session: ^0.1.21` (or current stable)
- `audio_service: ^0.18.15` (or current stable)

### New files

- `dart/app/lib/features/player/background/lecture_audio_handler.dart` —
  `BaseAudioHandler` subclass; adapts the stitched controller.
- `dart/app/lib/features/player/background/audio_session_controller.dart`
  — wraps `AudioSession.instance`; wires interruption + noisy events to
  the handler.
- `dart/app/lib/features/player/background/media_item_builder.dart` —
  builds a `MediaItem` from course + lecture metadata (resolves artwork
  URI with local-file fallback). Dispatches on `courseId.startsWith('ocw:')`
  to read from MITx vs. OCW course models.
- `dart/app/test/features/player/background/lecture_audio_handler_test.dart`
- `dart/app/test/features/player/background/audio_session_controller_test.dart`

### Modified files

- `dart/app/lib/bootstrap.dart` (or wherever `bootstrap()` lives) —
  `AudioService.init(...)` + `AudioSession.configure(...)` at startup.
- `dart/app/lib/features/player/providers/lecture_player_provider.dart`
  — attach the handler when a lecture's `LecturePlaybackController` is
  created; detach (via `stop()`) on dispose / lecture switch.
- `dart/app/lib/features/cast/providers/cast_controller.dart` — on
  `CastConnectionStatus.connected`, detach the `LectureAudioHandler`;
  on disconnect, the subsequent re-creation of the local player will
  re-attach via the normal `LecturePlayerProvider` init path.
- `dart/app/pubspec.yaml` — add the two packages above.

### Unchanged (by design)

- `dart/app/lib/features/player/controllers/lecture_playback_controller.dart`
  — the stitching / seek-serialization engine is left untouched. The
  handler is a consumer of its `snapshot` notifier.
- `dart/app/lib/features/player/widgets/lecture_video_player.dart` —
  in-app UI is unaffected.
- iOS `Info.plist` — `UIBackgroundModes: audio` is already present.
- Android `AndroidManifest.xml` — `FOREGROUND_SERVICE_MEDIA_PLAYBACK` and
  `POST_NOTIFICATIONS` are already present.
- Progress tracking providers / tables — continue to work unchanged
  because they subscribe to the same `PlaybackSnapshot` notifier that the
  audio handler reads from.

## Implementation Notes

**Implemented**: April 2026

### Key changes

- `dart/app/pubspec.yaml` — added `audio_service ^0.18.15` (resolved to
  0.18.18) and `audio_session ^0.1.21` (resolved to 0.1.25).
- New `dart/app/lib/features/player/background/` directory with four
  files:
  - `lecture_audio_handler.dart` — `BaseAudioHandler` adapter; forwards
    `play` / `pause` / `seek` / `fastForward` / `rewind` to the currently
    attached `LecturePlaybackController` and mirrors its
    `PlaybackSnapshot` into `playbackState`.
  - `audio_session_controller.dart` — subscribes to `audio_session`'s
    interruption and becoming-noisy streams; pauses on interruption
    begin, auto-resumes only when the platform signals `shouldResume` /
    `AUDIOFOCUS_GAIN` (modelled as `AudioInterruptionType.pause` on end)
    and no intervening noisy event cleared the auto-resume flag.
  - `media_item_builder.dart` — builds the lock-screen `MediaItem` from
    Drift caches. Dispatches on `courseId.startsWith('ocw:')` to read
    from the OCW or MITx sources; resolves artwork against the
    `courseImages` table (preferring a local `file://` URI) and falls
    back to the remote URL.
  - `audio_service_provider.dart` — `@Riverpod(keepAlive: true)`
    provider that throws unless overridden in the `ProviderScope`. Kept
    as an abstraction point for tests.
- `dart/app/lib/main.dart` — in `bootstrap()` calls
  `AudioService.init(...)` + `AudioSession.instance.configure(speech())`
  once, retains an `AudioSessionController.forSession(...)` for the
  process lifetime, and overrides `lectureAudioHandlerProvider` in the
  root `ProviderScope`.
- `dart/app/lib/features/player/providers/lecture_player_provider.dart`
  — added a `_wireBackgroundAudio` helper called from both the MITx
  `build()` path and `_buildOcw()`. It awaits the `MediaItem`, attaches
  to the handler when the cast session is not connected, listens to
  `castControllerProvider` to detach on cast-connect and re-attach on
  cast-disconnect, and registers `handler.detach` on provider dispose.

### Tests

- `test/features/player/background/lecture_audio_handler_test.dart` —
  12 tests covering attach/detach lifecycle, snapshot propagation,
  play/pause/seek/fast-forward/rewind delegation and clamping,
  seek-to-0 on replay from a completed snapshot, and no-op behaviour
  when no controller is attached.
- `test/features/player/background/audio_session_controller_test.dart` —
  5 tests driving fake `AudioInterruptionEvent` and becoming-noisy
  streams through the controller to verify pause / auto-resume /
  stay-paused semantics.

Full suite: 112 / 112 passing. `flutter analyze` clean.

### Deviations from spec

- `AudioSessionController` takes raw
  `Stream<AudioInterruptionEvent>` + `Stream<void>` streams rather than
  an `AudioSession` so it can be unit-tested without a live platform
  channel. The production path uses
  `AudioSessionController.forSession(...)` which wires up the real
  session.
- The `AudioServiceConfig` in `bootstrap()` omits
  `androidNotificationIcon`, `androidStopForegroundOnPause`, and
  `rewindInterval` because they match `audio_service`'s own defaults.
  The lints (`avoid_redundant_argument_values`) were flagging them —
  behaviour is identical.
- `fvm` is referenced in the project `CLAUDE.md` but is not installed
  on this machine. Implementation was verified with the system Flutter
  at `/Users/kristian/opt/flutter/bin/flutter` (3.38.5, Dart 3.10.4),
  which satisfies the `pubspec.yaml` SDK constraint (`^3.10.4`). The
  repo pins Flutter 3.41.0 via `.fvmrc`; a final check under that
  exact toolchain is still pending.
