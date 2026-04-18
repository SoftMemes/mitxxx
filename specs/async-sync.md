# Async Sync Specification

> **Version**: 1.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-18

## Description

Currently in the app there are too many edge cases around syncing metadata where things are running when they shouldn't or the UI freezes waiting on something to start/stop. This moves all metadata sync to a background isolate and a single class that knows about the sync operation taking place. This class should ensure that only a single logical metadata sync operation is running at a given point in time, either:

- A full metadata sync of all courses
- Refreshing the "list of lists"
- Refreshing an individual course
- Refreshing an individual lecture
- Or in the future any other operation

This reworks the way the "stale session" detection works. Instead of trying to fix things inside an interceptor and resume, it will detect a 401/403 error on any call, then after the login step up has been completed, cleanly restart the whole previously scheduled logical operations.

The UI interacts with this through "requests", e.g. pulling down to refresh in the home screen requests a full sync — these are always instant and non-blocking operations. Each screen has a loading status tied to the actual sync manager state, so that the loading state of the home screen is shown when syncing the whole set, the loading state on a course is shown when that course is being synced (or scheduled to be synced) for any reason and so on.

Video downloads should be managed via a separate single instance manager class. This runs concurrently with metadata syncs and interacts with it only when lectures/videos are removed from the sync, to ensure that these downloads stop immediately and the respective data is removed. The video download manager is solely responsible for all downloads, deletion, size estimation, etc.

The goals here are to:

1. Never block the UI
2. Always have at most one logical metadata sync operation running
3. Cleanly handle the stale session flow in a way that retries all requests to ensure clean results
4. Downloads running stably and offloaded from the main UI thread

Finally, include a "debugger" tool in the app enabled only for the dev version, accessible from the home screen menu. When opened it shows in technical terms what the metadata sync manager is doing, e.g. what logical operation, how many sub operations (individual downloads) are pending, and so on.

If it would help performance, then the database schema used may be updated to use different serialisation of blobs (protobufs over json or similar).

---

## Architecture & Design

### Isolate model

One long-lived **background isolate** ("sync isolate") is spawned at app start, after authentication, and torn down on sign-out. It hosts:

- the **Sync Manager** (state machine + request lifecycle)
- the isolate-local **Dio** HTTP client (with its own cookie jar loaded from the shared cookie file)
- the isolate-local **Drift** connection (opened via `DriftIsolate` / `NativeDatabase` against the same SQLite file the main isolate uses)

The main isolate retains its own Dio (for login WebView bootstrap and one-off UI calls) and its own Drift handle for read-only UI consumption. Serialization for the isolate boundary stays as **JSON blobs in the existing tables** — protobuf is deferred until profiling proves it's needed. No schema changes land with this work.

**Downloads stay on the main isolate.** The `VideoDownloadManager` continues to drive the `background_downloader` plugin from the root isolate; that plugin already runs transfers in native background services, so adding another isolate is unnecessary overhead.

### Sync Manager state machine

At any moment the manager is in exactly one of these states:

- `Idle` — no op running, no reauth pending.
- `Running(op)` — a single logical op is in flight.
- `Cancelling(op, nextRequest?)` — prior op is being torn down; a replacement request (if any) is staged to start once in-flight HTTP calls have acked their `CancelToken`.
- `AwaitingReauth(pendingRequest)` — a 401/403 surfaced; the manager has emitted `ReauthRequired` and is waiting for the main isolate to signal `reauthComplete`. `pendingRequest` is always the **latest** request captured while in this state — if the user taps something new while the login dialog is up, the old pending request is overwritten.

**Invariants:**

1. At most one `LogicalOp` executes at a time (goal #2).
2. No HTTP or DB call from inside the manager ever blocks the main isolate's event loop (goal #1).
3. All cancellation is cooperative via `CancelToken`; the manager does not forcibly kill workers.

### Logical op types

Implemented as a sealed `SyncRequest` hierarchy with a shared `scope` identifier:

| Op | Scope | Work |
|---|---|---|
| `FullSyncRequest` | `all-courses` | Fetch enrollments → reconcile membership (incl. userlists) → sync every course in the target set. |
| `ListsRefreshRequest` | `lists` | Fetch userlists **and reconcile memberships only** (no per-course content). Used when the user opens the list picker. |
| `CourseSyncRequest(courseId)` | `course:<id>` | Fetch outline → fetch each sequence's metadata → fetch each vertical's xblock. OCW courses take the OCW end-to-end path. |
| `LectureSyncRequest(courseId, sequenceId)` | `lecture:<seqId>` | Re-fetch the sequence's metadata and **every xblock within it**. This is the "refresh from the lecture detail page" action — a lecture in this app is a sequence with collapsible sections and a video player. |

The set is extensible — adding a new op means adding a new `SyncRequest` subclass and a matching handler in the manager's dispatch.

### Request lifecycle

1. UI calls a fire-and-forget method on the `SyncManager` facade (e.g. `requestFullSync()`, `requestCourseSync(courseId)`). These return `void` — the UI observes progress via Riverpod providers, never by awaiting.
2. The facade forwards a typed message over `SendPort` to the sync isolate.
3. The isolate's state machine handles it:
   - **Idle → Running(op)**: start immediately.
   - **Running(op) with identical request**: debounce — no-op. (e.g. two pull-to-refreshes within 200 ms.)
   - **Running(op) with different request**: cancel-and-replace. Fire `CancelToken`, transition to `Cancelling(op, nextRequest)`. When the last in-flight HTTP call acks cancellation, start `nextRequest`.
   - **AwaitingReauth**: overwrite `pendingRequest` with the new one. After reauth completes, run only the latest.
4. The isolate streams `SyncEvent`s back to the main isolate continuously: `opStarted`, `scopeStateChanged`, `subtaskProgress`, `removedVideoUrls`, `reauthRequired`, `opCompleted`, `opCancelled`, `opErrored`.
5. The main isolate's bridge translates events into Riverpod state.

**No queue.** At most one `LogicalOp` is "current" at any time; a replacement request while `Running` immediately cancels the running op rather than queueing behind it. Duplicate requests while running are treated as no-ops.

**Scope conflicts.** A narrower request always wins. A `CourseSyncRequest` arriving during a `FullSyncRequest` cancels the full sync and runs just the course. The user can pull-to-refresh the home again to re-trigger the full sync later.

### Isolate messaging protocol

Plain sealed Dart classes sent over `SendPort` in both directions. No protobuf, no JSON. Each class is immutable (freezed-friendly) and contains only types that transfer cheaply across isolates (strings, ints, DateTime, enums, Lists of same).

**Main → Isolate** (`SyncRequest` sealed class):

```dart
sealed class SyncRequest {}
class FullSyncRequest extends SyncRequest {}
class ListsRefreshRequest extends SyncRequest {}
class CourseSyncRequest extends SyncRequest { final String courseId; }
class LectureSyncRequest extends SyncRequest { final String courseId; final String sequenceId; }
class ReauthCompleted extends SyncRequest {}   // main → isolate after login finishes
class SignOut extends SyncRequest {}            // causes stopAll + isolate shutdown
```

**Isolate → Main** (`SyncEvent` sealed class):

```dart
sealed class SyncEvent {}
class OpStarted extends SyncEvent { final LogicalOp op; }
class ScopeStateChanged extends SyncEvent { final String scopeId; final ScopeState state; }
class SubtaskProgress extends SyncEvent { final String scopeId; final int completed; final int total; }
class RemovedVideoUrls extends SyncEvent { final List<String> urls; final String courseId; }
class ReauthRequired extends SyncEvent { final LogicalOp originatingOp; }
class OpCompleted extends SyncEvent { final LogicalOp op; }
class OpCancelled extends SyncEvent { final LogicalOp op; }
class OpErrored extends SyncEvent { final LogicalOp op; final String scopeId; final String message; }
class LogRecordForwarded extends SyncEvent { /* logging.LogRecord fields */ }
```

### Logging

All `package:logging` records emitted inside the isolate are forwarded to the main isolate via `LogRecordForwarded` and fed back into the existing `Logger.root` pipeline. Crashlytics, dev log view, analytics — all keep working unchanged. The dev debugger additionally subscribes to a recent-events ring buffer exposed by the isolate directly.

## Data Models

No Drift schema changes. The existing tables stay:

- `enrollments`, `outlines`, `sequences`, `xblocks`, `sanitized_xblocks` — JSON blobs as today.
- `downloaded_videos`, `course_list_memberships`, `unsupported_list_items` — unchanged.
- `course_sync_state` (or equivalent in `app_database`) — remains the source of truth for lastSyncedAt / lastError per course.

New **in-memory** models on the main isolate, mirrored from `SyncEvent`s:

- `ScopeState { status: idle|scheduled|syncing|error, lastSyncedAt?, errorMessage? }` keyed by scope id.
- `SyncManagerState { currentOp?, scopeStates: Map<String, ScopeState>, reauthPending: bool }`.

`ScopeState.status == scheduled` is a new state — surfaces the "this scope is part of the current op but its sub-tasks haven't started yet" case in the UI (two-state visual: shimmer when scheduled, stronger indicator when actively fetching).

## API Changes

### New classes

- `SyncManager` (main-isolate facade) — `requestFullSync()`, `requestListsRefresh()`, `requestCourseSync(courseId)`, `requestLectureSync(courseId, sequenceId)`, `signOut()`. All return `void`.
- `SyncIsolate` — owns the `Isolate` handle, the bidirectional `SendPort`s, spawn/shutdown lifecycle.
- `SyncIsolateEntry` — the isolate's top-level entry; constructs `SyncManagerCore` (the state machine) and wires it to the ports.
- `SyncManagerCore` — pure state machine; owns `LogicalOp` instances, `CancelToken`s, per-scope trackers. No Flutter/Riverpod imports.
- `LogicalOp` sealed hierarchy — one subclass per request type, each knows how to run itself given `Dio`, `AppDatabase`, `CancelToken`, event sink.
- `SyncDebuggerScreen` (dev-flavor only) — accessible from the home-screen overflow menu.

### Updated Riverpod providers

- `syncManagerProvider` — replaces `syncControllerProvider`. Exposes `SyncManager` facade + `SyncManagerState` stream.
- Per-screen derived providers:
  - `isSyncingAllProvider` — bool, watches manager state for current op = FullSync.
  - `courseScopeStateProvider(courseId)` — per-course ScopeState.
  - `lectureScopeStateProvider(sequenceId)` — per-sequence ScopeState.
- `reauthControllerProvider` — simplified: receives `ReauthRequired` events from the manager, drives the UI dialog, and sends `ReauthCompleted` back to the manager on successful login. No longer owns `PendingSyncOperation` — the isolate tracks what to re-run (always the latest request).

### Retired

- `SyncController` (the current in-main-isolate notifier) is deleted outright. No feature flag, no dual-maintenance.
- `PendingSyncOperation` sealed hierarchy in `reauth_provider.dart` is removed — the isolate owns pending-request tracking.
- The current `_SyncScheduler` priority queue logic is retired; cancel-and-replace removes its reason to exist.

## Coordination: Sync ↔ Downloads

One-way signal. When the sync manager computes that a set of video URLs have been dropped from the canonical course/lecture structure (existing `_cleanupRemovedVideos` / `_detectStaleDownloads` logic, moved into the isolate), it emits a `RemovedVideoUrls` event. The main isolate's bridge forwards this to the `VideoDownloadManager`, which:

1. Cancels any in-flight download tasks for those URLs.
2. Deletes downloaded files on disk.
3. Updates `downloaded_videos` rows.

The sync manager has **no knowledge** of download manager internals. The download manager has no knowledge of sync op lifecycle. The only coupling is this one event.

## Error Handling

### Stale session (401 / 403)

1. Any HTTP call inside the isolate that returns 401/403 raises a sentinel `StaleSessionException`.
2. `SyncManagerCore` catches it, fires the `CancelToken` for the whole op, clears partial in-memory tracker state, and transitions to `AwaitingReauth(originatingOp)`.
3. `ReauthRequired` event is emitted; the main-isolate `ReauthController` shows the existing reauth dialog + login flow (reused as-is from `lib/features/auth`).
4. If the user requests a **different** op while the dialog is up, the isolate overwrites `pendingRequest` — the latest request wins.
5. On successful login, the main isolate sends `ReauthCompleted`. The isolate restarts the latest pending request from scratch.

The restart is a **full** restart of the logical op — previously-successful per-course completions within that op are not skipped. Bandwidth cost is negligible because ETags + `If-None-Match` yield 304s on unchanged content (existing behavior retained).

### Per-scope failures (non-auth)

Inside a logical op, sub-task failures do not abort the op. Example: during a full sync, one course's outline fetch fails with a network error → that course's `ScopeState.status` becomes `error` with a human-readable message; other courses continue. The top-level op still completes normally.

The per-scope error surfaces in the UI as a small error badge on the affected tile/row; tapping it shows a short reason ("Network error", "Server unavailable", "Content unavailable"). Full stack traces are available in the dev debugger only.

### Cancellation

When an op is cancelled by a replacement:

1. Manager fires `CancelToken`, transitions to `Cancelling`.
2. Dio aborts in-flight requests; per-task handlers observe `CancelException` and return without writing to the DB.
3. Any DB writes that had already started are not rolled back explicitly — they're idempotent upserts, so leaving them is correct.
4. Once the cancel token count reaches zero, the replacement starts.

UI behavior: the moment a replacement request lands, the UI flips to the new op's loading state. No "cancelling…" visual. The isolate acks in the background.

### Offline

Requests are accepted unconditionally. The first network call fails; the op surfaces an `offline` error on the relevant scope. No pre-flight connectivity check. No request queue — the user retries when they're back online.

### Logged-out state

`SyncManager` rejects requests with an `UnauthenticatedException` until authentication completes. The isolate itself isn't spawned until the user is signed in.

## UI

### Loading-state contract

Each screen uses a derived Riverpod provider that exposes only the state it cares about:

- **Home screen**: `isSyncingAllProvider` (bool). Pull-to-refresh spinner tracks this. Course tiles additionally read `courseScopeStateProvider(id)` for per-tile shimmer/error badges.
- **Course screen**: `courseScopeStateProvider(id)` — the whole screen shows a loading indicator when this scope's status is `syncing`; individual sequences show their own status via `lectureScopeStateProvider(seqId)`.
- **Lecture screen**: `lectureScopeStateProvider(seqId)` — loading bar at top, error retry affordance on failure.

Each scope has **two active visuals**:

- `scheduled` — the scope is part of the current op but its sub-tasks haven't started yet. Faint shimmer.
- `syncing` — sub-tasks are in flight. Stronger indicator (progress bar / spinner).

No numeric progress is shown to end-users ("3 of 12 courses synced" is debugger-only). The production UI stays boolean per scope.

### Pull-to-refresh

Always instant and non-blocking. Tapping pull-to-refresh dispatches the request and returns immediately; the spinner reflects the manager's state stream, not any returned Future.

### Dev debugger

- **Entry**: overflow menu on the home screen (dev flavor only — guarded by `FlavorConfig.isDev`).
- **Contents**:
  - Current logical op, its scope, started-at, state (`running` / `cancelling` / `awaitingReauth` / `idle`).
  - Sub-operation counters: pending / in-flight / completed / errored.
  - Scrolling event log — state transitions, requests arriving, cancellations, reauth prompts, errors (truncated ring buffer of last ~500 events).
  - Download manager status: active / queued / paused downloads, bytes transferred.
- **Implementation**: subscribes to the same `SyncEvent` stream the main-isolate bridge consumes, plus a parallel subscription to the `VideoDownloadManager`'s existing state.

## Testing Strategy

### Unit (manager state machine)

Table-driven tests over `SyncManagerCore`, no isolate spawned. Cover:

- Idle → Running on first request.
- Running → Running (same request) = no-op (debounce).
- Running → Cancelling → Running (different request) = cancel-and-replace.
- Cancelling overwrite: second replacement while still cancelling overwrites `nextRequest`.
- Running → AwaitingReauth on simulated 401.
- AwaitingReauth → Running-latest on `ReauthCompleted`, including when the latest request differs from the originating op.
- Per-scope error isolation: one sub-task fails, op still completes with a mixed success/error per-scope state.

### Integration (real isolate)

Spawn the real sync isolate in a test harness. Verify:

- Message-protocol round trip: `SyncRequest` sent, `SyncEvent`s received.
- Cancellation propagates across the isolate boundary (Dio `CancelToken` actually aborts).
- Log forwarding: `Logger` calls inside the isolate surface in the main-isolate log stream.
- Drift isolate: reads/writes from both isolates don't corrupt state.

### Widget

Verify home-screen, course-screen, lecture-screen render correctly for each manager state (idle, scheduled, syncing, error). Use a fake `SyncManagerState` stream.

### Manual (not automated)

A short scripted e2e lives in the spec folder for QA: "force a 401 via expired cookie, verify reauth-then-restart sequence on all four op types."

## Deployment Plan / Rollout

- **Single PR**. Replace `SyncController` outright with the new `SyncManager` + isolate infrastructure. No feature flag, no dual-maintenance.
- The dev debugger is the only dev-flavor-gated surface (runtime check on `FlavorConfig.isDev`).
- No DB migration.
- No public surface changes outside the app.
- **Definition of done** per `dart/app/CLAUDE.md`: `fvm flutter analyze` prints `No issues found!` with zero ignores for this work.

## Key Files Reference

### Replaced / heavily modified

- `dart/app/lib/features/sync/providers/sync_controller.dart` — **deleted**; replaced by the new manager/isolate stack.
- `dart/app/lib/features/auth/providers/reauth_provider.dart` — simplified: subscribes to manager events, drives the login dialog, sends `ReauthCompleted`. `PendingSyncOperation` hierarchy removed.
- `dart/app/lib/features/sync/models/course_sync_state.dart` — extended with the new `scheduled` status and per-scope error-state model if needed.
- `dart/app/lib/features/downloads/providers/video_download_manager.dart` — adds an `onRemovedVideoUrls(List<String> urls, String courseId)` entry point consumed by the main-isolate bridge.
- `dart/app/lib/features/sync/fetchers/ocw_course_fetcher.dart` — made isolate-safe (no Flutter/Riverpod dependencies reachable from isolate).

### New files (proposed layout)

- `dart/app/lib/features/sync/manager/sync_manager.dart` — main-isolate facade + provider.
- `dart/app/lib/features/sync/manager/sync_manager_state.dart` — mirrored state model consumed by UI.
- `dart/app/lib/features/sync/isolate/sync_isolate.dart` — spawn/shutdown, port wiring.
- `dart/app/lib/features/sync/isolate/sync_isolate_entry.dart` — top-level isolate entry function.
- `dart/app/lib/features/sync/isolate/sync_manager_core.dart` — pure state machine (no Flutter imports).
- `dart/app/lib/features/sync/isolate/logical_op.dart` — sealed `LogicalOp` hierarchy + handlers.
- `dart/app/lib/features/sync/isolate/sync_messages.dart` — sealed `SyncRequest` / `SyncEvent` classes.
- `dart/app/lib/features/sync/isolate/isolate_logger_bridge.dart` — forwards `logging` records over the port.
- `dart/app/lib/features/sync/providers/sync_providers.dart` — per-screen derived providers (isSyncingAll, courseScopeState, lectureScopeState).
- `dart/app/lib/features/sync/debugger/sync_debugger_screen.dart` — dev-flavor-only screen.
- `dart/app/lib/features/sync/debugger/sync_event_ring_buffer.dart` — recent-events buffer.

### Touched for wiring

- `dart/app/lib/core/network/dio_client_provider.dart` — isolate-local Dio construction path.
- `dart/app/lib/core/storage/database_provider.dart` / `app_database.dart` — `DriftIsolate` setup so the sync isolate can open the same DB file.
- `dart/app/lib/features/courses/screens/lecture_screen.dart`, course screen, home screen — swap `syncControllerProvider` reads for the new per-scope providers and rewire pull-to-refresh.
- `dart/app/lib/features/auth/widgets/reauth_gate.dart` — points at the simplified `ReauthController`.
- `dart/app/lib/main.dart` / `main_dev.dart` / `main_prod.dart` — spawn/shutdown `SyncIsolate` alongside auth lifecycle.

### Analytics

- `dart/app/lib/core/analytics/analytics_events.dart` — existing `logSyncStart`/`logSyncComplete`/`logSyncFailure` stay as-is, called from the isolate. Scope constants (`kScopeAllCourses`, `kScopeCourse`, `kScopeSection`) reused and extended with `kScopeLists` for the list-of-lists op.

---

*Ready for implementation. Run `/implement-spec async-sync` to begin.*
