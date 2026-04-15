# Data Usage Specification

> **Version**: 1.3 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-15

## Description

A "Data Usage" entry in the settings menu opens a full-screen page showing how much local storage the app is using, split into two categories: course metadata and downloaded videos. Each category has its own delete control. Deleting videos only removes the video files; deleting all data removes both videos and cached course metadata, which will be re-fetched on the next sync.

---

## UX & Navigation

- **Settings entry**: A `ListTile` labelled "Data Usage" placed near the bottom of the settings screen, above the Sign Out button.
- **Destination**: Tapping it pushes a new full-screen route (`/settings/data-usage`).
- **Page layout**: Two rows — one for metadata, one for videos — each showing a label, its formatted size, and a delete button. A third "Delete all data" action appears below both rows (e.g. a text button or outlined button) to clear everything at once.

---

## Storage Breakdown

### Display granularity
Totals only — one number for metadata, one for videos. No per-course breakdown.

### Course metadata size
Calculated as the SQLite database file size on disk (the `.db` file managed by Drift). Reported as a single number labelled "Course metadata".

### Downloaded videos size
Sum of `bytesDownloaded` across all rows in the `DownloadedVideos` table where `status = 'downloaded'`. Labelled "Downloaded videos".

### Size formatting
Auto-scaled:
- < 1 MB → show in KB (e.g. "512 KB")
- ≥ 1 MB, < 1 GB → show in MB with one decimal (e.g. "42.3 MB")
- ≥ 1 GB → show in GB with two decimals (e.g. "1.24 GB")

### Snapshot behaviour
Sizes are calculated once when the screen is opened. After a delete action completes, the displayed sizes refresh to reflect the new state.

---

## Delete Controls

### Delete videos only

- **Trigger**: A "Delete" button inline with the "Downloaded videos" row.
- **Confirmation**: Dialog — e.g. "Delete all downloaded videos? This will remove X from your device. Course metadata and your enrollment list will not be affected."
- **On confirm**:
  1. Delete all physical video files from disk.
  2. Remove the corresponding `DownloadedVideos` DB rows.
  3. Refresh the displayed sizes on the page.
- **In-progress downloads**: Not cancelled — only already-downloaded files are deleted.

### Delete all data

- **Trigger**: A "Delete all data" button below both rows (visually separated, e.g. with a divider).
- **Confirmation**: Dialog — e.g. "Delete all app data? This will remove all downloaded videos and cached course content. Everything will be re-downloaded the next time you sync." Two actions: "Delete all" (destructive) and "Cancel".
- **On confirm**:
  1. Delete all physical video files from disk.
  2. Call the existing `clearAll()` DB method — clears every table including `CachedEnrollments`, `CachedCourseSync`, and `DownloadedVideos`. The app returns to a blank state identical to a fresh install.
  3. Navigate the user to the home screen, which will show the empty/logged-in state with a "Sync now" button (the same `_EmptyState` widget already used when there is no cached data).
- **Re-sync behaviour**: No automatic sync is triggered. The user taps "Sync now" on the home screen when ready, exactly as they would after a first login.

### Per-course deletion
Out of scope for this feature.

---

## Key Files

**New files:**
- `dart/app/lib/features/settings/screens/data_usage_screen.dart` — the full-screen data usage page

**Modified files:**
- `dart/app/lib/features/settings/screens/settings_screen.dart` — add "Data Usage" `ListTile` above Sign Out
- `dart/app/lib/core/router/app_router.dart` — add `/settings/data-usage` route
- `dart/app/lib/core/storage/app_database.dart` — add a helper to sum `bytesDownloaded` for downloaded videos and expose the DB file path for metadata size calculation

---

## Implementation Notes

**Implemented**: April 2026

**New files:**
- `dart/app/lib/features/settings/screens/data_usage_screen.dart`

**Modified files:**
- `dart/app/lib/core/storage/app_database.dart` — added `dbFilePath()`, `getTotalDownloadedBytes()`, `clearDownloadedVideosAndGetPaths()`
- `dart/app/lib/core/router/app_router.dart` — added `/settings/data-usage` route
- `dart/app/lib/features/settings/screens/settings_screen.dart` — added "Data Usage" ListTile above Sign Out

**Deviations from spec:**
- The settings screen had already been refactored to have a separate "Settings" preferences tile (not shown in spec). "Data Usage" was inserted above Sign Out as specified.

---

## Out of Scope

- Per-course video or metadata deletion
- Live size updates while downloads are in progress
- Cancelling in-progress downloads from this screen
- Automatic re-sync after deleting all data
