# Casting Support Specification

> **Version**: 1.1 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-15

## Description

Add a cast button to the video player overlay that lets users stream the current lecture to a Chromecast (Android + iOS) or AirPlay receiver (iOS). The receiver plays the full lecture as a queue of video segments — mirroring the stitched multi-segment playback already done locally. Scrubbing, pausing, speed control, and vertical (chapter) tracking all work while casting, with the phone acting as a remote control.

---

## Architecture & Design

### High-level flow

1. User taps the cast icon in the player overlay controls.
2. **Chromecast**: Cast SDK route picker appears (standard SDK UI). **AirPlay**: iOS `AVRoutePickerView` appears (system native).
3. On device selection, the app builds a **queue** of `MediaQueueItem` entries — one per video segment (vertical) in the current lecture — using remote CDN URLs.
4. The queue is loaded into the cast session starting at the current position (the first item is seeked to the current within-segment offset).
5. While casting, the phone shows a **cast controller screen**: scrub bar spanning the full lecture, chapter list of verticals, play/pause, speed selector, and a stop-cast button.
6. Position is polled from the receiver every ~1 second and reflected in the scrub bar.
7. As the receiver advances through queue items, the app tracks which vertical is active and highlights it in the chapter list.
8. On disconnect / error, the app falls back to local player mode, paused at the last known position.

### State machine

```
NotCasting  →  (user taps cast + selects device)  →  Connecting
Connecting  →  (session established, queue loaded) →  Casting
Casting     →  (user taps stop / disconnect)       →  NotCasting
Casting     →  (error / receiver turned off)       →  NotCasting (resume local, paused)
Casting     →  (user opens different lecture)      →  Casting (queue replaced)
```

---

## Cast Protocol & Library

| Concern | Decision |
|---|---|
| Chromecast (Android + iOS) | `flutter_cast_framework` package |
| AirPlay (iOS only) | `AVRoutePickerView` embedded in player overlay via platform channel or `av_route_picker` plugin |
| Receiver app | **Default Media Receiver** — no custom receiver needed |
| Minimum OS | Unchanged from existing app minimums |

### Why Default Media Receiver
The Default Media Receiver supports:
- Media queue / playlist with `QUEUE_LOAD`, `QUEUE_NEXT`, `QUEUE_JUMP`
- Seek within item (`SEEK`)
- Playback rate (`SET_PLAYBACK_RATE`) — most Chromecast devices support this
- No deployment, no App ID required beyond the default

---

## Stitching & Playback Approach

Each lecture sequence is represented as a flat list of `(verticalId, remoteUrl)` pairs. On cast start:

```
queueItems = lecture.verticals
  .where((v) => v.mp4Url != null)
  .mapIndexed((i, v) => MediaQueueItem(
      media: MediaInfo(contentUrl: v.mp4Url!, ...),
      autoplay: true,
      startTime: i == currentSegmentIndex ? currentSegmentOffset : 0,
  ));
castSession.loadQueue(queueItems, startIndex: currentSegmentIndex);
```

- **Always uses remote CDN URLs** — cast never serves local files.
- The queue index maps 1:1 to the vertical list. The app keeps `_castQueueIndex` in sync with the receiver's `currentItemIndex` to know which vertical is active.
- When the user opens a different lecture while casting, `loadQueue` is called again to replace the queue in the existing session.

---

## Sync & UI During Casting

### Cast controller screen (replaces full player while casting)

```
┌─────────────────────────────────────────────┐
│  [←]  Lecture Title              [■ Stop]   │
│                                              │
│  Casting to: Living Room TV                 │
│                                              │
│  ──────────●──────────────────────  12:34   │
│  |    |    |    |    |    |    |            │
│  [▶/⏸]          [speed]                     │
│                                              │
│  Chapters                                   │
│  ▶ 1. Introduction          0:00            │
│    2. Key Concepts           4:12  ←active  │
│    3. Discussion             9:55            │
│    ...                                       │
└─────────────────────────────────────────────┘
```

- **Scrub bar**: full lecture timeline with segment boundary markers (same as `UnifiedScrubBar`). Seek fires on drag-end and tap (matching local behaviour).
- **Position sync**: poll receiver position every 1 second via `CastSession.getMediaStatus()`, update scrub bar and active chapter highlight.
- **Vertical sync**: when `mediaStatus.currentItemId` changes, find the corresponding vertical index and update the chapter list highlight.
- **Speed control**: show the existing speed selector; send `SET_PLAYBACK_RATE` to the receiver.
- **Download button**: unchanged — download and cast are independent.

### Cast button in player overlay

- The cast icon appears in the existing player overlay controls row (alongside play/pause, fullscreen, etc.).
- On Chromecast: tapping shows the SDK route picker.
- On iOS: tapping shows `AVRoutePickerView` (handles both Chromecast and AirPlay).
- While a session is active, the icon changes to the active-cast style (filled, coloured).

---

## Error Handling

| Scenario | Behaviour |
|---|---|
| No devices found | SDK shows its own empty state in the route picker — no custom UI |
| Cast interrupted (network drop, TV off) | Fall back to local player, paused at last known position |
| Queue item fails to load on receiver | Skip to next item (Default Media Receiver default behaviour); show a brief snackbar |
| Cast SDK init failure | Log warning; hide cast button gracefully (degrade silently) |
| App backgrounded during cast | Cast continues unaffected; position sync resumes on foreground |

---

## Platform Scope

| Platform | Chromecast | AirPlay |
|---|---|---|
| Android | ✓ via flutter_cast_framework | — |
| iOS | ✓ via flutter_cast_framework | ✓ via AVRoutePickerView |

---

## Key Files Reference

| File | Change |
|---|---|
| `lib/features/player/widgets/lecture_video_player.dart` | Add cast button to overlay controls; switch to cast controller UI when casting |
| `lib/features/player/widgets/cast_controller.dart` | **New** — cast controller widget (scrub bar, chapter list, speed, stop) |
| `lib/features/player/controllers/cast_playback_controller.dart` | **New** — manages cast session, queue loading, position polling, vertical sync |
| `lib/features/player/widgets/unified_scrub_bar.dart` | Reuse as-is for cast controller scrub bar |
| `ios/Runner/...` | Add GoogleCast.framework, AVRoutePickerView platform channel |
| `android/app/build.gradle` | Add cast-framework dependency |
| `pubspec.yaml` | Add flutter_cast_framework (+ av_route_picker or equivalent) |
| `lib/features/courses/models/sequence.dart` | Verify vertical list exposes mp4Url for queue building |

## Implementation Notes

**Implemented**: April 2026

**Key Changes**:
- `pubspec.yaml`: Added `flutter_chrome_cast: ^1.4.5`, `flutter_to_airplay: ^2.1.0`
- `ios/Podfile`: Bumped platform to `14.0`
- `ios/Runner/Info.plist`: Added `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `audio` background mode
- `ios/Runner/AppDelegate.swift`: Init `GCKCastContext` with default receiver ID
- `android/app/src/main/AndroidManifest.xml`: Cast options provider meta-data, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission, `MediaNotificationService`
- `lib/features/player/models/vertical_segment.dart`: Added `String? remoteVideoUrl` field
- `lib/features/cast/models/cast_queue_item.dart`: New — plain queue item model
- `lib/features/cast/models/cast_state.dart`: New — `CastState` + `CastConnectionStatus`
- `lib/features/cast/providers/cast_controller.dart`: New — `@Riverpod(keepAlive: true)` wrapping `flutter_chrome_cast`; session lifecycle, queue load, seek/play/pause/speed, 1s position poll
- `lib/features/cast/widgets/cast_button.dart`: New — iOS uses `AirPlayRoutePickerView`, Android uses `IconButton` + `_DevicePickerDialog`
- `lib/features/cast/widgets/cast_controller_panel.dart`: New — replaces `LectureVideoPlayer` while casting
- `lib/features/player/providers/lecture_player_provider.dart`: Added `remoteVideoUrl` population, `castQueue` getter
- `lib/features/player/widgets/lecture_video_player.dart`: Added `CastButton` to overlay; converted to `ConsumerStatefulWidget`
- `lib/features/courses/screens/lecture_screen.dart`: Watches cast state; swaps in `CastControllerPanel` when connected; handles connect/disconnect lifecycle
