# Progress Tracking Specification

> **Version**: 1.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-17

## Overview

Add in-app-only "Continue where you left off" progress tracking for courses.
The feature is scoped to the Flutter app only — nothing syncs to any remote.
Each course keeps a single "last played" position; the course outline screen
gains a top-of-list **Continue** section pointing at it. Tapping any lecture
(Continue tile or the regular section-list tile) resumes from the saved
position.

### Non-goals

- Remote sync / cross-device progress.
- Per-lecture position history (only the last-played lecture is remembered).
- Manual "mark complete" / "reset" UI (clearing is implicit only).
- Aggregated cross-course Continue rail on the home screen.

## User Experience

### Happy path

1. User opens a lecture, taps play.
2. The first actual playback event (first video frame rendered after user tap)
   creates/updates a `course_positions` row for this course with
   `(lectureId, positionSeconds)`.
3. Position is persisted throttled (~every 5 s while playing, and on pause,
   seek, dispose, and app-background).
4. User closes the lecture or the app.
5. Later, user opens the course outline. A **Continue** section appears at the
   top with a single tile — the same tile style as in the regular section list.
   The tile's leading icon is `Icons.play_circle` (filled) to indicate this is
   the tracked entry; non-tracked tiles keep `Icons.play_circle_outline`.
6. The *same* lecture also appears under its original section header below,
   but with the filled `Icons.play_circle` leading icon (so the user can spot
   the "current" one in both places).
7. Tapping either tile opens the lecture; the player seeks to the saved
   position. For MITx, the stitched lecture screen's existing "expanded
   section follows playback position" behavior auto-expands the correct
   vertical at the resumed position.

### Completion advance

- When the player reaches the end of a lecture (`>= duration - 2 s`), the
  row advances: `(lectureId, positionSeconds)` is overwritten with
  `(nextLectureId, 0)`.
- "Next lecture" = walk the course's outline in flattened order
  (sections → sequences for MITx; sections → lectures for OCW) and pick
  the first lecture *after* the current one that is **video-bearing**.
- **Video-bearing** means:
  - MITx sequence: at least one vertical has a video.
  - OCW lecture: `cachedOcwLectures.mp4Url != null`.
- If no such next lecture exists, the row is cleared (Continue section
  disappears).

### Switching lectures

If the user opens a *different* lecture before finishing the current one, the
previous lecture's position is **discarded** — the row is overwritten with the
new lecture and the new position. There is no per-lecture memory.

### Visibility

- If no `course_positions` row exists for the course, **the Continue section
  is not rendered**. The outline shows only the existing section structure
  exactly as it does today.
- The Continue section header uses the existing `_SectionHeaderTile` widget
  with the text "Continue" — same visual style as other section headers.

### Course removal / sign-out

When a course is dropped (list-reconciliation removes it, sign-out wipes
data), its `course_positions` row is deleted along with the rest of its
cache.

## Data Model

New Drift table — **user-state**, preserved across schema upgrades (same
treatment as `DownloadedVideos`, `SelectedLists`, `CourseListMemberships`).

```dart
/// One row per course tracking the user's last-played lecture and position.
/// User state: preserved across schema upgrades (never in `_cacheTables`).
///
/// [lectureId] is polymorphic by course type:
///   - MITx courses (courseId = `course-v1:...`): sequence block id
///     (e.g. `block-v1:MITxT+...+type@sequential+block@...`).
///   - OCW courses (courseId = `ocw:...`): `CachedOcwLectures.lectureId`.
class CoursePositions extends Table {
  TextColumn get courseId => text()();
  TextColumn get lectureId => text()();
  RealColumn get positionSeconds => real()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {courseId};
}
```

### Migration

- Schema version: bump `AppDatabase.schemaVersion` from 9 → 10.
- The existing `onUpgrade` already calls `m.createAll()` at the end and only
  drops tables named in `_cacheTables`. `course_positions` is NOT added to
  `_cacheTables`, so it will be created on upgrade and preserved thereafter.
- Migration test: on upgrade from v9 → v10, existing DownloadedVideos,
  SelectedLists, CourseListMemberships rows must be untouched;
  `course_positions` table must exist.

### Cleanup hooks

Extend existing database methods:

- `AppDatabase.deleteCourseCache(courseId)` — add
  `await (delete(coursePositions)..where((t) => t.courseId.equals(courseId))).go();`
  so reconciliation drops the row when a course leaves the selection.
- `AppDatabase.clearAllAndGetDownloadPaths()` — add a delete for
  `coursePositions`. Sign-out should wipe progress too.

## State Management

### New provider module: `lib/features/progress/`

```
lib/features/progress/
  models/
    course_position.dart              # Freezed model wrapping CoursePosition row
  providers/
    course_position_provider.dart     # watchCoursePosition(courseId) -> Stream<CoursePosition?>
    lecture_position_provider.dart    # lecturePosition((courseId, lectureId)) -> double (seconds, 0 if no match)
    progress_tracker_provider.dart    # ProgressTracker service
  services/
    progress_tracker.dart             # record/advance/validate logic
    next_video_lecture_resolver.dart  # walks outline / OCW lectures to find next video-bearing entry
test/features/progress/
  ...
```

### `ProgressTracker` service

```dart
class ProgressTracker {
  ProgressTracker({required this.db, required this.ref});

  final AppDatabase db;
  final Ref ref;

  /// Throttled position write (5 s min between persists per courseId).
  /// Called from the player on playback ticks.
  Future<void> recordPosition({
    required String courseId,
    required String lectureId,
    required double positionSeconds,
  });

  /// Immediate, non-throttled write. Called on pause / seek / dispose /
  /// app-backgrounded / completion advance.
  Future<void> flushPosition({
    required String courseId,
    required String lectureId,
    required double positionSeconds,
  });

  /// Called when the player reports end-of-lecture. Computes the next
  /// video-bearing lecture and overwrites the row; clears if none.
  Future<void> recordCompletion({
    required String courseId,
    required String completedLectureId,
  });

  /// Called after a successful course sync. If the current row's lectureId
  /// no longer exists in the course outline, clears the row.
  Future<void> validateTrackedLecture(String courseId);
}
```

### `NextVideoLectureResolver`

Encapsulates outline walking. One method per platform:

```dart
Future<String?> nextMitxVideoSequence({
  required String courseId,
  required String fromSequenceId,
});

Future<String?> nextOcwVideoLecture({
  required String courseId,
  required String fromLectureId,
});
```

- MITx: flatten sections → sequenceIds in outline order, find the successor
  after `fromSequenceId`, and for each candidate consult cached outline /
  sequence data to determine if the sequence is video-bearing. If the cached
  outline already exposes a per-sequence block count that includes video
  types (e.g. `block_counts.video > 0` or equivalent), prefer that; otherwise
  walk `cachedSequences` JSON for video verticals.
- OCW: read `db.getOcwLectures(courseId)` (already ordered by sectionOrder,
  lectureOrder), find the successor with `mp4Url != null`.

Return the id of the next video-bearing lecture or `null` when none remains.

### Player integration

**MITx — `LectureScreen` / `LecturePlayer`**

- On init: read `lecturePosition((courseId, sequenceId))`. If > 0, seek the
  stitched player to that `globalPosition` as soon as schedule is ready
  (before auto-play, if auto-play is enabled).
- On playback: subscribe to the player's position stream (or
  `LecturePlayerState.globalPosition`) and call
  `progressTracker.recordPosition(...)` with throttling.
- On pause / seek end / dispose: call `progressTracker.flushPosition(...)`.
- On `LecturePlayerState.isComplete` transitioning to `true`: call
  `progressTracker.recordCompletion(courseId: ..., completedLectureId: sequenceId)`.
  The tracker advances the row (or clears it).

**OCW — `OcwLectureScreen` / `_OcwVideoAreaState`**

- On `_initController` completion: if `lecturePosition((courseId, lectureId))`
  > 0 and the player is in position 0, call `seekTo(Duration(milliseconds:
  savedMs))` before `play()`.
- On position changes from `VideoPlayerController`: `recordPosition` (throttled).
- On pause / dispose: `flushPosition`.
- On completion (`vpc.value.position >= vpc.value.duration - 2 s`): call
  `recordCompletion(courseId: ..., completedLectureId: lectureId)`.

**"Interacted with" trigger**

First playback event = first position update with `positionSeconds > 0`
(or `isPlaying == true`). A pure lecture-screen open with no play never
creates a row. HTML-only MITx sequences and `mp4Url == null` OCW lectures
therefore never become Continue entries.

### Sync integration

`SyncController.syncCourse` — on successful completion, invoke
`progressTracker.validateTrackedLecture(courseId)` so structure drift
silently clears a now-missing tracked lecture.

## UI Changes

### `course_outline_screen.dart`

Both MITx and OCW paths gain a Continue sliver at the top of their scroll
view. Rendered conditionally:

```dart
final positionAsync = ref.watch(courseWatchPositionProvider(courseId));
// ... inside CustomScrollView slivers, after DownloadProgressBar:
if (positionAsync.valueOrNull != null)
  _ContinueSection(
    courseId: courseId,
    position: positionAsync.value!,
    // For MITx: pass outline so we can resolve sequence title/section.
    // For OCW: pass lectures list from the existing _OcwOutlineBody future.
  ),
```

`_ContinueSection`:

- Renders `_SectionHeaderTile(title: 'Continue')` followed by one of:
  - A `_SequenceTile` (MITx) reusing the existing widget.
  - An `_OcwLectureTile` (OCW) reusing the existing widget.
- The underlying tile widgets gain an `isTracked` flag that flips the leading
  icon from `play_circle_outline` → `play_circle` (filled). The tracked
  lecture in its *original* section also receives `isTracked: true` so the
  user sees the same filled icon in both places.

### `lecture_screen.dart` (MITx) and `ocw_lecture_screen.dart` (OCW)

- No new route params. Resume is implicit: the player provider / video
  controller checks the stored position on init and seeks.
- The "Play from beginning" tooltip/icon on the MITx `_SequenceTile` leading
  button is retained for *non-tracked* sequences. For the tracked sequence,
  the icon becomes the filled variant and tapping it still resumes (the
  whole tile resumes uniformly — no explicit "restart from 0" escape
  hatch, by design).
- OCW lecture tiles gain the same tracked-vs-non-tracked icon distinction.

## Edge Cases & Error Handling

| Scenario | Behavior |
|---|---|
| Course has no tracked row | Continue section hidden; outline unchanged. |
| Tracked lecture deleted after re-sync | `validateTrackedLecture` clears row silently; Continue hidden on next render. |
| Advance target has no video (HTML-only next lecture) | Resolver skips it and continues walking until it finds a video-bearing lecture. |
| No video-bearing next lecture exists (end of course) | Row is cleared; Continue hidden. |
| User switches to a different lecture mid-playback | Row overwritten with new lecture + new position; previous lecture's position lost. |
| App force-killed mid-playback | Position is accurate up to the last throttled persist (<= 5 s lag in the worst case). |
| Small saved positions (< 5 s) | Honored exactly — resume at exact position. No rounding to 0. |
| Duplicate display (Continue tile + regular section tile for the same lecture) | Both tiles rendered unchanged; both resume; both show the filled `play_circle` icon. |
| Concurrent writes | Not applicable — single-user single-app-instance. The throttle is per-course and internal. |
| HTML-only MITx vertical inside a tracked sequence | Position tracking still works (based on stitched `globalPosition`); the existing vertical-auto-expand handles which vertical is "current". |
| User rewinds | Position updates to the new (smaller) value — we store current, not max-watched. |
| Course removed via list reconciliation | `deleteCourseCache` wipes the row. |
| Sign-out | `clearAllAndGetDownloadPaths` wipes the row. |

## Testing Strategy

Unit tests only (per stated preference). Target files:

- `test/features/progress/services/next_video_lecture_resolver_test.dart`
  - MITx: given a mock outline with mixed video/no-video sequences, verify
    that `nextMitxVideoSequence` skips HTML-only sequences and stops at the
    first video-bearing one. Edge: last video-bearing sequence → returns
    `null`. Edge: `fromSequenceId` missing from outline → returns `null`.
  - OCW: given a lectures list with some `mp4Url == null`, verify skip
    behavior; edge cases as above.
- `test/features/progress/services/progress_tracker_test.dart`
  - `recordPosition` is throttled (rapid calls coalesce within 5 s).
  - `flushPosition` is always immediate.
  - `recordCompletion` overwrites the row with the resolver's next lecture
    at position 0, or deletes it when resolver returns `null`.
  - `validateTrackedLecture` deletes the row when the tracked lectureId is
    no longer in the outline; no-op otherwise.
- `test/features/progress/end_threshold_test.dart`
  - A tiny helper `isLectureComplete(double position, double duration)`
    returns `true` for `position >= duration - 2`, `false` otherwise.
- `test/core/storage/app_database_test.dart` (extend existing)
  - `deleteCourseCache` removes the course's `course_positions` row.
  - `clearAllAndGetDownloadPaths` removes all `course_positions` rows.

No widget tests, no integration tests — manual QA covers the UI surface:

1. Play an MITx lecture halfway, close, re-open course → Continue appears, tile shows filled icon, tap resumes at saved position with correct vertical expanded.
2. Play to end → Continue advances to the next sequence that has video; HTML-only sequences between are skipped.
3. Play last video-bearing sequence to end → Continue disappears.
4. Repeat for an OCW course.
5. Un-select a course list → Continue disappears for that course (verified via re-select).
6. Kill the app mid-playback → reopen → position restored (within 5 s).

## Analytics

One new event: `continue_resume`. Parameters:

- `course_id` (string)
- `lecture_id` (string)
- `platform` (string: `mitx` | `ocw`)
- `position_seconds` (double)

Fired from the Continue tile's `onTap` in `_ContinueSection` *before*
navigation. The existing `section_open` / `section_play` events continue to
fire for the regular section tile taps — `continue_resume` is additive, only
when the user enters via the Continue section.

## Key Files Reference

### New files

- `dart/app/lib/features/progress/models/course_position.dart`
- `dart/app/lib/features/progress/providers/course_position_provider.dart`
- `dart/app/lib/features/progress/providers/lecture_position_provider.dart`
- `dart/app/lib/features/progress/providers/progress_tracker_provider.dart`
- `dart/app/lib/features/progress/services/progress_tracker.dart`
- `dart/app/lib/features/progress/services/next_video_lecture_resolver.dart`
- `dart/app/test/features/progress/services/next_video_lecture_resolver_test.dart`
- `dart/app/test/features/progress/services/progress_tracker_test.dart`
- `dart/app/test/features/progress/end_threshold_test.dart`

### Modified files

- `dart/app/lib/core/storage/app_database.dart`
  - Add `CoursePositions` table.
  - Bump `schemaVersion` 9 → 10.
  - Add CRUD helpers (`getCoursePosition`, `watchCoursePosition`, `upsertCoursePosition`, `deleteCoursePosition`).
  - Extend `deleteCourseCache` and `clearAllAndGetDownloadPaths` to include `course_positions`.
- `dart/app/lib/features/courses/screens/course_outline_screen.dart`
  - Add `_ContinueSection` sliver at the top for both MITx and OCW paths.
  - Add `isTracked` flag to `_SequenceTile` and `_OcwLectureTile` (flips leading icon variant).
- `dart/app/lib/features/player/providers/lecture_player_provider.dart` (MITx)
  - On init: seek to saved position.
  - Wire playback ticks / pause / seek / dispose to `ProgressTracker`.
  - On `isComplete`: call `recordCompletion`.
- `dart/app/lib/features/courses/screens/ocw_lecture_screen.dart` (OCW)
  - On `_initController`: seek to saved position.
  - Wire ticks / pause / dispose to `ProgressTracker`.
  - On end-of-video (`position >= duration - 2 s`): call `recordCompletion`.
- `dart/app/lib/features/sync/providers/sync_controller.dart`
  - After successful `syncCourse`: call `progressTracker.validateTrackedLecture(courseId)`.
- `dart/app/lib/core/analytics/analytics_service.dart` and `analytics_events.dart`
  - Add `logContinueResume(...)` method and `kEventContinueResume` constant.

### Unaffected (by design)

- `dart/app/lib/features/courses/screens/home_screen.dart` — no change; Continue is course-outline-only.
- Routing (`app_router.dart`) — no new routes or query params; resume is provider-driven.
- Downloads / sync pipeline data model — no schema changes beyond the new user-state table.

---

*Spec refined via `/refine-spec progress-tracking`. Ready for
`/implement-spec progress-tracking`.*
