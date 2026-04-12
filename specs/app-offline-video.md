# App Offline Video Specification

> **Version**: 2.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-12

## Description

Building on the offline-first mode (which caches course structure and content), this feature adds optional video downloading so the app can provide a fully offline experience including video playback. Users can download videos at course, sequence, or vertical granularity. Downloaded videos are deduplicated by URL and are never re-downloaded unnecessarily.

---

## Architecture & Design

### Download Manager

A new `VideoDownloadManager` service (Riverpod provider) handles all download logic:
- Maintains a download queue with a concurrency cap of **3 simultaneous downloads**
- Uses platform background download mechanisms:
  - **iOS**: `URLSession` background tasks (survives app termination)
  - **Android**: `WorkManager` (survives app termination)
  - Flutter package: `flutter_downloader` or `background_downloader` (to be decided during implementation)
- Downloads **MP4 format only** (using the `mp4Url` from `ParsedVideoBlock`)
- Stores files in **app-private storage** (not accessible from Files app/gallery; deleted on uninstall)

### Deduplication by URL

- The **URL is the primary key** for downloaded videos
- One file on disk per unique URL, regardless of how many courses/sequences/verticals reference it
- A `DownloadedVideo` database table tracks `url → localFilePath` mappings (see Data Models)
- Before starting any download, check this table; skip if URL already has a local file

### URL Change Detection

- Runs **on every course refresh** (each time `SyncController` syncs a course)
- After syncing xblocks, compare stored `mp4Url` values in `ParsedVideoBlock` against `DownloadedVideo` table
- If a URL has changed for a block that was previously downloaded:
  - Mark the old download as **stale** in the database (do not delete the file yet)
  - Show an in-app indicator on the download button (update-available state)
  - When the user triggers re-download, fetch only the new URL; the old file is deleted after new download completes
- Videos whose URLs have not changed are untouched

### Playback Integration

- `VideoBlock` widget checks `DownloadedVideo` table for the video's `mp4Url`
- If a local file exists: use `VideoPlayerController.file(localFile)` — **always prefer local**, even when online
- If no local file and offline: show error message "Video not available offline — download it first"
- If no local file and online: stream as before (existing behavior)

---

## Data Models

### New database table: `DownloadedVideos`

Added to `AppDatabase` (Drift):

```dart
class DownloadedVideos extends Table {
  // Primary key: the MP4 URL
  TextColumn get url => text()();

  // Absolute path to the downloaded file on disk
  TextColumn get localFilePath => text()();

  // Track which courses reference this URL (JSON list of courseIds)
  // Used for cleanup when a course is unenrolled
  TextColumn get courseIds => text()();

  // 'downloaded' | 'downloading' | 'failed' | 'stale'
  TextColumn get status => text()();

  // 0.0 - 1.0, for in-progress downloads
  RealColumn get progress => real().withDefault(const Constant(0.0))();

  // How many bytes downloaded so far (for resume)
  IntColumn get bytesDownloaded => integer().withDefault(const Constant(0))();

  // Total file size in bytes (0 if unknown)
  IntColumn get totalBytes => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {url};
}
```

### New: `DownloadedVideo` Dart model

```dart
class DownloadedVideo {
  final String url;
  final String localFilePath;
  final List<String> courseIds;
  final DownloadStatus status; // enum: downloaded, downloading, failed, stale
  final double progress;
  final int bytesDownloaded;
  final int totalBytes;
}
```

No changes to existing tables (`CachedXblocks`, `CachedOutlines`, etc.).

---

## Download Logic

### Triggering a Download

Download buttons appear at three levels:
1. **Course level** — in `CourseOutlineScreen`, downloads all videos in all sequences/verticals
2. **Sequence level** — in `CourseOutlineScreen` sequence rows, downloads all videos in that sequence
3. **Vertical level** — in `ContentScreen` vertical items, downloads the video in that vertical (if any)

When the user taps a download button:
1. Collect all `mp4Url` values in scope (course/sequence/vertical)
2. Filter out URLs already in `DownloadedVideos` with status `downloaded`
3. Enqueue remaining URLs in `VideoDownloadManager`
4. Update database status to `downloading` and progress to `0.0`

### Download Execution

For each queued URL:
1. Start platform background download to a temp file in app-private storage
2. On progress updates: update `bytesDownloaded` and `progress` in database → UI reactively updates
3. On completion: move temp file to permanent path, update status to `downloaded`
4. On failure: auto-retry up to **3 times** with exponential backoff; after 3 failures, set status to `failed`
5. On interruption (network loss, app close): resume from `bytesDownloaded` offset when conditions restore (platform background task handles this)

### Resume Logic

- Uses HTTP `Range` header: `Range: bytes=<bytesDownloaded>-`
- CloudFront serves unsigned MP4s and supports range requests
- If server returns 200 instead of 206 (range not supported), restart from 0

### Storage Full Handling

- If download fails with a disk-full error: set status to `failed`, show error to user ("Not enough storage space")
- No automatic eviction of existing downloads

---

## UI / UX Behavior

### Download Button States

| State | Icon | Behavior |
|---|---|---|
| Not downloaded | Download arrow icon | Tap to start downloading |
| Downloading | Circular progress indicator | Tap to cancel |
| Downloaded | Checkmark icon | Tap → show confirmation dialog "Remove download?" |
| Failed | Warning/error icon | Tap to retry |
| Stale (URL changed) | Download arrow + badge | Tap to re-download updated version |

### Progress Display

Shown inline at each level (course, sequence, vertical) during active downloads or when partially downloaded:

```
■■■□□□□□□□  3 / 10 videos
```

- Fraction format: `X / Y videos`
- Linear progress bar
- Progress is computed from the `DownloadedVideos` table by counting URLs with status `downloaded` vs total video URLs in scope
- For a course: aggregate across all sequences/verticals
- For a sequence: aggregate across its verticals
- For a vertical: shows progress for its single video (0%, in-progress %, or 100%)

### Delete Flow

When the user taps a checkmark (downloaded) button:
- Show confirmation dialog: "Remove downloaded videos for [Course/Sequence/Vertical name]?"
- On confirm: delete files from disk, remove rows from `DownloadedVideos` for those URLs (only if no other course references them — see courseIds field)

### Offline Playback Error

When a user tries to play a video that has no local file while offline:
- Display in the player area: "Video not available offline. Connect to the internet or download this video first."
- No change to existing online-streaming behavior

---

## Sync Integration

### On Course Refresh (`SyncController`)

After syncing all xblocks for a course:
1. Collect all current `mp4Url` values from the freshly synced `CachedXblocks`
2. Query `DownloadedVideos` for all rows associated with this courseId
3. For each downloaded URL no longer present in current xblocks: delete file, remove row (video block was removed from course)
4. For each downloaded URL that has changed (old URL in DB, new URL in xblock): mark old entry as `stale`

### On Course Unenroll / Removal

When a course is removed from the app:
1. Find all `DownloadedVideos` rows where `courseIds` includes this courseId
2. Remove courseId from `courseIds` for each row
3. For rows where `courseIds` is now empty: delete the file and remove the row
4. For rows still referenced by other courses: keep the file, just update `courseIds`

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Network error during download | Auto-retry up to 3 times; show error icon after 3 failures |
| CDN returns non-200/206 | Treat as download failure; retry |
| Disk full | Fail immediately with user-visible error message |
| App killed during download | Platform background task resumes automatically |
| Video URL changed | Mark stale, show update indicator, re-download only new URL on next user-initiated download |
| Video block removed from course | Delete download on next course refresh |

---

## Platform Notes

### iOS

- Use `URLSession` background configuration for downloads that survive app termination
- App-private storage: `NSApplicationSupportDirectory` or `NSCachesDirectory` (prefer Application Support to survive low-storage purges)
- No additional permissions needed (no access to photo library or shared storage)

### Android

- Use `WorkManager` with `NETWORK_TYPE_CONNECTED` constraint for reliable background downloads
- Store files in `getFilesDir()` (app-private, no READ/WRITE_EXTERNAL_STORAGE permission needed on Android 10+)
- On Android < 10: may need `WRITE_EXTERNAL_STORAGE` if targeting older APIs

---

## Key Files to Modify

| File | Change |
|---|---|
| `core/storage/app_database.dart` | Add `DownloadedVideos` table, bump schema version |
| `features/courses/widgets/video_block.dart` | Check local file before streaming; show offline error |
| `features/courses/screens/course_outline_screen.dart` | Add download buttons + progress at course and sequence level |
| `features/courses/screens/content_screen.dart` | Add download button + progress at vertical level |
| `features/sync/providers/sync_controller.dart` | Add URL change detection + stale marking after xblock sync |

### New Files

| File | Purpose |
|---|---|
| `features/downloads/providers/download_manager.dart` | `VideoDownloadManager` Riverpod provider + queue logic |
| `features/downloads/providers/download_state_provider.dart` | Per-URL and per-scope (course/sequence/vertical) download state providers |
| `features/downloads/widgets/download_button.dart` | Reusable download button widget (all states) |
| `features/downloads/widgets/download_progress_bar.dart` | Fraction + bar progress widget |
| `features/downloads/models/download_status.dart` | `DownloadStatus` enum |
