# Gradual Sync Specification

> **Version**: 1.1 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-15

## Description

Right now the app syncs the whole course before you can see any of it. This feature makes sync gradual: the course outline appears as soon as the top-level overview is downloaded, then each lecture (sequence) syncs in order. Each lecture row shows its sync status inline. When a lecture is synced it becomes tappable. Tapping an unsynced lecture queues it to the front of the sync queue.

---

## Behaviour

### Sync trigger
- Sync is triggered by the **existing home-screen sync flow** (auto on first login, manual refresh button). There is no new separate trigger.
- The current `syncAll` / `syncCourse` logic is **replaced** by the gradual sync path — one code path, not two.

### Two-phase sync per course
1. **Phase 1 — Outline fetch** (fast): fetch course outline (chapters + sequence list) and store it. As soon as this completes the course outline screen can render the full sequence list.
2. **Phase 2 — Sequence content sync** (sequential): fetch each sequence's content (verticals, xblock HTML) one at a time, in course order. Each sequence becomes accessible as soon as its fetch completes.

### Sync unit
- The atomic sync unit is a **sequence** (what the UI calls a "lecture" — one row in the course outline, containing one or more verticals).
- "Synced" for a sequence means: xblock/HTML content fetched and stored. Video download is a separate optional action as today.

### Sync order
- Sequences sync **strictly sequentially** — one at a time, in course order.
- Exception: if the user taps an unsynced sequence, that sequence is **moved to the front** of the queue and syncs next.

### Re-open behaviour
- If a course was previously synced and the user opens it again, lectures are **immediately accessible from cache**.
- Re-sync only happens when the user explicitly taps the manual refresh button — no automatic background re-sync on open.

---

## UI / UX

### Course outline screen — sequence rows
Each sequence row shows an inline status indicator on the trailing edge (right side), consistent with the per-course status icons on the home screen:

| State | Indicator |
|---|---|
| Not yet synced | Clock / hourglass icon (muted colour) |
| Currently syncing | Small circular progress spinner |
| Synced | Check-circle icon (green) |
| Sync failed | Error icon (red) |

### Tappability
- **Synced** sequences: tappable, open the lecture screen as today.
- **Unsynced / syncing** sequences: tappable; tapping moves them to the front of the sync queue (does not open the lecture screen — user must wait for that sequence to finish syncing).
- **Failed** sequences: tappable to retry (queue to front).

### Error handling
- If a sequence sync fails: mark that row with an error icon, continue syncing the remaining sequences in order.
- No full stop / no modal — sync continues for all other sequences.

### Course-level sync indicator
- The existing per-course spinner/sync status on the home screen continues to reflect the overall sync state (spinning while any phase is in progress).

---

## Architecture & Design

### SyncController changes
- Replace the current all-or-nothing `syncCourse` implementation with a two-phase approach:
  1. Fetch and persist the course outline (`/api/course_home/outline/{courseId}`, `/api/learning_sequences/v1/course_outline/{courseId}`) — emit `SyncStatus.syncing` at the course level while this runs.
  2. Walk the sequence list in order; for each sequence fetch and persist its content (`/api/courseware/sequence/{blockId}` + xblock vertical fetches). Emit per-sequence progress events after each.
- A queue (e.g. a simple ordered list) tracks which sequences are pending / in-progress / done. Moving a sequence to the front mutates this queue.

### New state: per-sequence sync status
- Add a per-sequence sync state model, parallel to the existing `CourseSyncState`:

```
SequenceSyncState {
  sequenceId: String
  status: SequenceSyncStatus  // idle | syncing | synced | error
  lastSyncedAt: DateTime?
  error: String?
}
```

- The `SyncController` provider exposes this per-sequence state so the course outline screen can watch it.

### CourseOutlineScreen changes
- Watch the new per-sequence sync state provider.
- Render the inline status indicator on each sequence row.
- On tap of an unsynced row: call `syncController.prioritiseSequence(courseId, sequenceId)` (queue to front).
- Sequence rows remain rendered/visible even before sync (data comes from the outline, not sequence content).

### Persistence
- No new DB tables required. The existing sequence/xblock tables are populated by the gradual sync as today; the sync state is in-memory in the SyncController provider (not persisted — on app restart sequences show as "not synced" until re-checked or re-synced, consistent with current behaviour).

---

## Key Files to Modify

| File | Change |
|---|---|
| `lib/features/sync/providers/sync_controller.dart` | Refactor `syncCourse` into two-phase outline-then-sequences; add per-sequence state emission; add `prioritiseSequence` |
| `lib/features/sync/models/course_sync_state.dart` | Add `SequenceSyncState` model and `SequenceSyncStatus` enum |
| `lib/features/courses/screens/course_outline_screen.dart` | Watch per-sequence sync state; render inline status; handle tap-to-queue-front |
| `lib/features/courses/widgets/` (sequence row widget, if extracted) | Add status indicator |

---

## Verification

1. **First open after login**: Home screen auto-sync starts → open a course → outline list appears immediately after phase 1 completes (before any sequences are fetched) → sequences show "not synced" initially → spinners appear one by one in order as each sequence syncs → check icons appear when done.
2. **Tap to prioritise**: While sync is running, tap a sequence near the end of the list → that sequence moves to the front and syncs next (confirmed by its spinner appearing ahead of others).
3. **Access synced lecture**: Tap a check-circle sequence → opens lecture screen as expected.
4. **Tap unsynced lecture**: Tap a not-yet-synced sequence → does not open lecture screen; sequence moves to front and begins syncing.
5. **Sequence failure**: Simulate a network failure for one sequence → error icon shown on that row, remaining sequences continue syncing.
6. **Re-open cached course**: Fully synced course, close and reopen → all sequences immediately accessible; no auto-sync; only re-syncs when manual refresh tapped.
7. **Home screen sync status**: Sync icon spins on home screen during gradual sync; stops when all sequences complete.
