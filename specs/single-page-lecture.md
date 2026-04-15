# Single-Page Lecture Specification

> **Version**: 2.0 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-15

## Description

Replace the current per-vertical page navigation (with auto-forward hacks) with a single unified lecture page. All verticals in a sequence are rendered together: a single stitched video plays the lecture end-to-end, and the non-video content is displayed as a collapsible list below the video that stays in sync with playback.

---

## Architecture & Design

### Page Structure

```
┌─────────────────────────────┐
│       Video Player          │  ← stitched, full-lecture video
│   [unified scrub bar]       │  ← single timeline; segment dividers if supported
└─────────────────────────────┘
│ ▶ Section 1 title      3:42 │  ← collapsed (play button + title + duration)
├─────────────────────────────┤
│ ▼ Section 2 title      1:15 │  ← expanded (active; HTML content rendered below)
│   [safe HTML content here]  │
├─────────────────────────────┤
│ ▶ Section 3 title      2:08 │  ← collapsed
└─────────────────────────────┘
```

- The video player is pinned at the top (sticky or always in view).
- Below it is a scrollable list of all verticals in the sequence.
- Only one section is expanded at a time.

### Video Stitching

- The player receives an **ordered list of video URLs** (one per vertical that has a video).
- **Offline**: `file://` paths to downloaded MP4s.
- **Online**: CDN HTTPS URLs (e.g. `d3tsb3m56iwvoq.cloudfront.net/transcoded/{hash}/video_custom.mp4`).
- Segments play back-to-back sequentially; the player tracks a **global time offset** for the full lecture.
- Each segment's start time in global coordinates is pre-computed: `segmentStartTime[i] = sum of durations of segments 0..i-1`.
- The scrub bar spans the **total combined duration**. If the underlying player (e.g. `video_player` / `better_player`) supports chapter markers, draw dividers at each segment boundary.

### State Model

```dart
class LecturePlayerState {
  final List<VerticalSegment> segments;  // ordered list of all verticals
  int activeSegmentIndex;                // currently expanded section
  double globalPosition;                 // current playback position in seconds (global)
  bool isPlaying;
  bool userOverrideActive;               // true when user manually expanded a section
}

class VerticalSegment {
  final String verticalId;
  final String title;
  final String? videoUrl;        // null if no video
  final double? videoDuration;   // null if no video
  final double globalStartTime;  // pre-computed global offset
  final String? safeHtmlContent; // rendered content (HTML blocks only; no problems)
}
```

---

## Content Rendering

### What is shown in each section

- **Section header** (always visible): vertical title + video duration (e.g. `3:42`) + play button (if has video).
- **Expanded content**: safe HTML only. Interactive elements (problem sets, assessments, drag-and-drop, JS widgets) are **excluded entirely** and will not appear anywhere in the app. Users are expected to complete assessments on the web.
- Verticals with no HTML content that also have no video still appear in the list with their title (collapsible, but empty when expanded).

### Safe HTML policy

Render HTML xblock content with a whitelist of safe tags (text, images, tables, basic formatting). Strip all `<script>`, `<iframe>`, form elements, and any interactive xblock types.

---

## Sync Behavior

### Video → Content sync (auto)

1. A position listener fires periodically during playback (e.g. every 500 ms).
2. Compute which segment the current `globalPosition` falls in.
3. If `userOverrideActive == false` and the computed segment differs from `activeSegmentIndex`:
   - Update `activeSegmentIndex`.
   - Animate the newly active section into view (smooth scroll).
   - Collapse the previous section, expand the new one.
4. If `userOverrideActive == true`, skip step 3 **until** the video crosses the next segment boundary, at which point clear `userOverrideActive` and resume normal sync.

### Content → Video sync (manual expand)

- User taps a collapsed section header to expand it.
- Set `userOverrideActive = true`.
- Expand the tapped section, collapse others.
- Auto-sync resumes at the next segment boundary.

### Play button on a section

- Seeks the video to `segmentStartTime[i]` (global offset).
- Starts playback.
- Clears `userOverrideActive`.
- Smooth-scrolls the video player into view.

### Scrubbing

- Scrubbing the unified scrub bar seeks to an absolute global position.
- On seek completion, recompute active segment and update the expanded section immediately.
- Clears `userOverrideActive`.

---

## Navigation

- **No next/back buttons** on the lecture page. All verticals are rendered inline.
- At the **end of the lecture** (last segment finishes):
  - Video stops.
  - Last section stays expanded.
  - Show a completion UI: e.g. a "Lecture complete" banner and a button to go to the next lecture/sequence in the course outline (if one exists).
- Course-level navigation (back to outline, etc.) remains via existing app navigation patterns.

---

## Error Handling

- If a video segment **fails to load** mid-playback:
  - Pause playback.
  - Show an error message (snackbar or inline) indicating which segment failed.
  - User can retry or dismiss and skip.
- If all segments for a lecture fail, show a full-page error with retry.
- Segments with no video are silently skipped in the playlist; they still appear in the content list.

---

## Offline vs Online

The `LecturePlayerState` is populated the same way regardless of mode:

| Mode    | Video URL source                              |
|---------|-----------------------------------------------|
| Offline | Local file path from download manager         |
| Online  | CDN URL from LMS API xblock metadata          |

No special-casing in the player or sync logic. The abstraction is resolved at the data-loading layer before the lecture page is opened.

---

## Key Files to Modify / Create

| File | Change |
|------|--------|
| `lib/features/courses/screens/lecture_screen.dart` | **New** — replaces per-vertical ContentScreen for sequences |
| `lib/features/courses/widgets/vertical_section_tile.dart` | **New** — collapsible section row with play button |
| `lib/features/player/providers/lecture_player_provider.dart` | **New or refactor** — manages stitched playback state & sync |
| `lib/features/player/models/lecture_player_state.dart` | **New** — state model above |
| `lib/features/courses/screens/content_screen.dart` | **Remove** navigation to per-vertical page; route to LectureScreen |
| `lib/features/courses/utils/safe_html.dart` | **New or extend** — HTML sanitizer for xblock content |

---

## Implementation Notes

**Implemented**: April 2026

**Key files created**:
- `dart/app/lib/features/player/models/vertical_segment.dart` — Freezed model
- `dart/app/lib/features/player/models/lecture_player_state.dart` — Freezed model
- `dart/app/lib/features/player/controllers/lecture_playback_controller.dart` — video stitching engine
- `dart/app/lib/features/player/widgets/unified_scrub_bar.dart` — custom scrub bar with segment dividers
- `dart/app/lib/features/player/widgets/lecture_video_player.dart` — player widget (raw video_player, no Chewie)
- `dart/app/lib/features/player/providers/lecture_player_provider.dart` — Riverpod AsyncNotifier
- `dart/app/lib/features/courses/screens/lecture_screen.dart` — main screen
- `dart/app/lib/features/courses/widgets/vertical_section_tile.dart` — collapsible section row
- `dart/app/lib/features/downloads/utils/resolve_playable_uri.dart` — local vs CDN URI helper

**Key files modified**:
- `dart/app/lib/core/router/app_router.dart` — route updated to `LectureScreen`
- `dart/app/lib/features/courses/utils/xblock_parser.dart` — added `sanitizeXBlockHtml`

**Files deleted**: `content_screen.dart`, `video_block.dart`, `auto_advance_provider.dart`, `problem_block.dart`

**Deviation**: Did not use Chewie in the new player — its tight binding to a single `VideoPlayerController` would require rebuilding the entire Chewie widget on every segment swap. Used raw `video_player` with a small custom overlay instead.

---

## Out of Scope

- Interactive problems/assessments (users go to web).
- Completion tracking sync back to LMS (separate spec).
- Downloading individual segments on demand (offline assumes all segments already downloaded).
- Subtitle/transcript display (future spec).
