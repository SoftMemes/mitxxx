# App True Offline Specification

> **Version**: 1.2 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-12

## Overview

Convert the app from online-with-offline-support (read-through cache) to a true offline-first experience. Offline is the default mode. Network access is only triggered by user-initiated sync actions. The existing read-through cache logic is fully replaced by a local SQLite cache that is populated during explicit sync.

---

## Architecture & Design

### Core Principle

Offline is the default. The app reads all content from local SQLite. Network is only used when:
1. The user initiates a sync (global or per-course)
2. A video is played (streamed from CloudFront — no offline video in this phase)

### Session Management

- Auth tokens/cookies are persisted to secure storage on first login
- On cold start with no network: app loads from local cache with no auth check
- When sync is triggered (and network is available): app checks session validity and re-authenticates via Keycloak OAuth2 if needed (transparent to user)
- If session is expired and user triggers sync: step up to re-login flow, then proceed with sync
- Single account only: logging out clears all cached metadata from SQLite

---

## Data Models / Local Storage

All metadata is stored in the existing SQLite database (`app_database`).

### Tables / Structures to Add or Modify

| Data | What to Cache |
|---|---|
| Enrolled courses | Course ID, title, enrollment metadata, last-synced timestamp |
| Course outline | Sections → sequences → verticals (IDs + titles, tree structure) |
| Xblock HTML content | Full rendered HTML per vertical (keyed by vertical block ID), including embedded video `data-metadata` JSON |
| Sync state | Per-course: `syncing`, `synced`, `error`, `last_synced_at` |

### Not Cached (This Phase)

- Video binary content (streamed on demand)
- Problem/assessment state (read-only display from cached HTML)

---

## Sync Strategy

### Global Refresh (Home Screen)

A refresh button on the home screen triggers a full sync:
1. Fetch current enrollment list from `mitxonline.mit.edu/api/v1/enrollments/`
2. Add newly enrolled courses; mark de-enrolled courses (keep cached data)
3. For each enrolled course, in parallel: sync course metadata (see below)
4. Show a per-course spinner while each course syncs
5. On individual course failure: keep old cached data, show error badge on that course card

### Per-Course Refresh

Each course card also has its own refresh button to sync a single course independently.

### Course Metadata Sync (per course)

For each course:
1. `GET /api/course_home/outline/{course_id}` → sections + sequences
2. `GET /api/learning_sequences/v1/course_outline/{course_id}` → sequences + verticals
3. For each vertical: `GET /xblock/{vertical_block_id}` → cache full HTML response
4. Update `last_synced_at` timestamp in DB

### Initial Sync (First Login)

- Network required on first launch to authenticate and perform initial sync
- Home screen shows enrolled course list immediately as each course is discovered
- Per-course spinner shows while metadata syncs for each course
- App is usable immediately for any course whose sync has completed

### Partial Sync Failure

- If sync fails mid-course (network drops, timeout, etc.): preserve previously cached data for that course
- Show error badge on the affected course card
- Other courses that synced successfully are unaffected

---

## UI Changes

### Home Screen

- **Refresh button**: top-right or prominent FAB, triggers global sync
- **Per-course refresh button**: on each course card
- **Per-course sync spinner**: shown on the course card while that course is syncing
- **Error badge**: shown on course card if last sync failed (e.g., red icon)
- **Last synced timestamp**: shown on each course card (e.g., "Synced 2h ago")

### Lecture Page (Sequence Viewer) — Reworked Navigation

Previously: all verticals in a sequence listed on one scrollable page.

New behavior:
- Show **one vertical at a time** (one page = one vertical)
- **Prev / Next buttons** fixed at the bottom of the screen
- At the first vertical of a sequence: Prev button is disabled
- At the last vertical of a sequence: Next button is disabled
- **Progress bar** at top or bottom indicating position within the sequence (e.g., filled portion = 3/7)
- Content area renders the cached xblock HTML for the current vertical

### Video Block (Offline State)

When device is offline and user taps a video block:
- Display a message: "Video unavailable offline — connect to internet to stream"
- No playback attempt

---

## Video Playback Behavior

### Auto-Advance (Full-Screen Completion)

- When a video completes in full-screen, auto-advance to the **next video in the same sequence**
- "Next video" = the next xblock of type `video` within the current sequence, scanning forward across verticals
- If advancing moves to a video in the next vertical: navigate the lecture page to that vertical automatically
- If there is no next video in the sequence: exit full-screen and remain on the current page

### Close / Exit Full-Screen Before Completion

- Dismiss the full-screen player
- Return to the lecture page
- Scroll the page so the video block that was playing is visible on screen

---

## Error Handling

| Scenario | Behavior |
|---|---|
| No network on cold start | Load from cache; no error shown unless cache is empty |
| No network + empty cache | Show empty state: "No courses cached yet. Connect to sync." |
| Sync fails for a course | Keep old cached data; show error badge on course card |
| Xblock HTML fetch fails during sync | Retry once; on second failure, mark that vertical as failed, continue syncing others |
| Session expired during sync | Transparently re-authenticate; if re-auth fails, show login prompt |
| Video played while offline | Show inline error message in the video block |
| No enrolled courses | Show empty state: "No enrolled courses found." with a refresh button |

---

## Key Files to Modify

These are likely targets based on the Flutter app structure under `app/`:

- `lib/features/auth/` — session persistence, step-up re-auth on sync
- `lib/features/courses/` — course list screen, sync logic, per-course spinners/error badges
- `lib/features/courseware/` or `lib/features/lecture/` — vertical-by-vertical navigation, prev/next buttons, progress bar
- `lib/features/player/` or `lib/features/video/` — auto-advance logic, scroll-to-block on close
- `lib/data/app_database.dart` (or equivalent) — new tables/columns for outline, xblock HTML, sync state
- `lib/services/` or `lib/repositories/` — replace read-through cache with offline-first SQLite reads + explicit sync

---

## Implementation Notes

**Implemented**: April 2026

**Key files created:**
- `dart/app/lib/features/sync/models/course_sync_state.dart` — `CourseSyncState` freezed model + `SyncStatus` enum
- `dart/app/lib/features/sync/providers/sync_controller.dart` — sync orchestrator (global + per-course)
- `dart/app/lib/core/network/connectivity_provider.dart` — online/offline stream provider
- `dart/app/lib/features/courses/screens/fullscreen_video_screen.dart` — landscape fullscreen player + auto-advance

**Key files modified:**
- `dart/packages/mitx_api/lib/src/dio_client.dart` — added `hasCookies` getter
- `dart/app/lib/core/storage/app_database.dart` — added `CachedCourseSync` table, schema v3
- `dart/app/lib/features/auth/providers/auth_provider.dart` — offline-first cold start (cookie check, no network)
- `dart/app/lib/features/courses/providers/` — all 4 providers converted to pure cache reads
- `dart/app/lib/features/courses/models/outline.dart` — added `SequenceInfo` + `sequences` map
- `dart/app/lib/features/courses/screens/home_screen.dart` — global+per-course refresh, spinners, error badges, last-synced label, auto-sync on empty cache
- `dart/app/lib/features/courses/screens/course_outline_screen.dart` — real sequence titles
- `dart/app/lib/features/courses/screens/content_screen.dart` — `PageView` one-vertical-at-a-time, prev/next, progress bar, fullscreen open/return
- `dart/app/lib/features/courses/widgets/video_block.dart` — offline check, fullscreen button

**Deleted:**
- `dart/app/lib/core/utils/cache_fetch.dart` — unused stale-while-revalidate helper

---

## Out of Scope (This Phase)

- Downloading video content for offline playback (future spec)
- Progress tracking / completion state sync
- Multiple accounts
- Manual cache size management (logout clears cache)
