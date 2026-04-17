# Course Shortlist Sync Specification

> **Version**: 1.0 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-17

## Description

Currently the app syncs all of the enrolled courses from the MIT portal. I need this to change so that instead the user can select to sync one or more of "all enrolled", or any of the playlists available on https://learn.mit.edu/ (e.g. the custom lists under "My List").

Note that this can include OpenCourseWare courses that are not yet supported; for now exclude these courses when syncing and only include MIT Learn native ones.

UX-wise this needs to update the app onboarding flow. There will be two states — onboarding before any lists have been selected, then later an option to change the lists to sync in settings.

In onboarding there's a wizard that requires that:
1. The user logs in; when successful,
2. The user selects at least one of the lists (enrolled or custom list), then gets to the home screen where syncing starts.

In the menu there's a new option for "Courses" where the user can again change the courses to sync based on the same options. Include a message there about how the courses have to be enrolled or managed via the MIT Learn portal.

Once a list is selected, future sync operations will sync all courses inside that list as the data is refreshed — so if a new course is enrolled, it shows up on the next sync. If a course is no longer in the sync set, it should be removed from the app along with all of its data including videos, without confirmation from the user.

## Goals

- Let the user restrict sync to a curated set of lists rather than everything enrolled.
- Support two list sources: "All enrolled" (from mitxonline) and user-created lists from `learn.mit.edu/dashboard/my-lists`.
- Make list membership the single source of truth: adding a course to a selected list upstream causes it to sync; removing it causes a full local delete (videos, progress, caches).
- Keep existing users' behavior unchanged on update by auto-migrating them to an "All enrolled" selection.

## Non-Goals

- In-app list management (create/rename/delete lists). Users manage lists on learn.mit.edu.
- Cross-device syncing of the selection itself — selection is local per install.
- OpenCourseWare course support. OCW courses inside lists are surfaced visually but never downloaded. Real OCW support is tracked separately.
- Other list sources on learn.mit.edu beyond "my lists" (subscribed paths, bookmarks, curated recommendations).
- Preserving watch progress across a remove-then-re-add cycle. When a course leaves the sync set it is fully wiped.

## User Flows

### First-launch onboarding (no selection yet)

1. **Disclosure modal** — existing "About MITxxx" disclosure from `app-onboarding.md` runs first, unchanged. Dismiss to continue.
2. **Login** — existing login flow against mitxonline.mit.edu. SSO at sso.ol.mit.edu covers learn.mit.edu in the same session; no separate login step.
3. **List selection (new)** — full-screen step:
   - Header: "Choose what to sync".
   - List picker (see UI spec below). User toggles one or more lists.
   - Primary CTA: "Continue", disabled until ≥1 list selected.
   - No skip, no back-out-of-app. Back navigates to login (clears session).
   - **Empty state**: if the user has zero enrolled courses AND zero custom lists, block with copy "No lists found — enroll in a course or create a list at MIT Learn." Button: "Open MIT Learn" deep-links to `https://learn.mit.edu/dashboard/my-lists`. User stays on step.
4. **Home screen** — normal home; first sync starts immediately using the existing sync indicator. No dedicated first-sync screen.

### Changing the selection later (settings → Courses)

1. Menu has a new "Courses" entry (top-level in settings, alongside existing items).
2. Tapping opens a full-screen list-selection page.
3. Page shows:
   - Short hint line: "Manage your enrolled courses and lists at MIT Learn." + "Open MIT Learn" button.
   - The list picker pre-toggled to the current selection.
   - App bar: "Save" (primary) commits and closes; back (leading) discards and closes.
   - Pull-to-refresh on this page re-fetches the list-of-lists only; triggers re-auth prompt if session has expired.
4. Tapping Save:
   - Persists the new selection.
   - Immediately triggers a sync with reconciliation (see Sync Reconciliation).
   - Returns to the prior screen.
5. Tapping back discards changes silently (standard Flutter nav; no confirmation).

### List-of-lists refresh

- In normal operation, the list-of-lists is refreshed whenever the home-screen course list is refreshed (pull-to-refresh there). This keeps the settings page fast without extra fetches.
- On the settings page, pull-to-refresh refreshes list-of-lists only (not sync).
- If a fetch fails auth, show the persisted cached list and a re-login prompt.

## Data Model

All persisted in Drift (same DB as existing course cache).

### Table: `selected_lists`

| Column | Type | Notes |
|---|---|---|
| `list_id` | TEXT PK | Synthetic id. For "All enrolled": constant `"all-enrolled"`. For a learn.mit.edu list: upstream user-list id. |
| `source` | TEXT | Enum: `enrolled` \| `learn_my_list`. |
| `name` | TEXT | Human name at time of last refresh (for display when offline/cached). |
| `selected_at` | INTEGER | Epoch ms, when the user most recently added this list to the selection. |

Presence in this table = selected. Removing a row = deselected.

### Table: `available_lists` (cache of list-of-lists for UI)

| Column | Type | Notes |
|---|---|---|
| `list_id` | TEXT PK | Same space as `selected_lists.list_id`. |
| `source` | TEXT | `enrolled` \| `learn_my_list`. |
| `name` | TEXT | |
| `total_course_count` | INTEGER | Includes unsupported courses (OCW etc). |
| `fetched_at` | INTEGER | Epoch ms of last successful fetch. |

Written on every list-of-lists refresh. Used to render the picker when offline / when learn.mit.edu is briefly unreachable.

### Course → list membership

Existing course rows get an additional association table to support ref-counted reconciliation:

### Table: `course_list_membership`

| Column | Type | Notes |
|---|---|---|
| `course_id` | TEXT | Open edX course id, e.g. `course-v1:MITxT+24.09x+1T2025`. |
| `list_id` | TEXT | FK to `selected_lists.list_id`. |
| PK | (`course_id`, `list_id`) | |

On each sync, this table is rebuilt to match upstream list contents (for currently-selected lists only). A course whose membership count drops to zero is deleted end-to-end.

## MIT Learn API Integration

### Known (existing)

- `GET mitxonline.mit.edu/api/v1/enrollments/` — used for the "All enrolled" list contents. No new work.

### Unknown (discovery subtask)

Reverse-engineering of learn.mit.edu playlist APIs is **part of this spec**, to be completed before Flutter work lands.

**Discovery plan:**

1. Capture mitmproxy flows from learn.mit.edu covering: dashboard/my-lists, opening a list, contents of a list, login/refresh.
2. Extend `python-tools/mitx-client/` (do not create a new tool dir — auth and conventions are shared):
   - Add commands to list the user's custom lists and dump a single list's contents.
   - Document discovered endpoints, request/response shapes, list ID format, course-identification format, and how to detect MIT Learn native vs OCW courses in list items. Update `python-tools/mitx-client/CLAUDE.md`.
3. Confirm that the existing SSO session (from the login flow in CLAUDE.md) transparently covers learn.mit.edu.
4. Only once endpoints are documented do Flutter data-layer changes begin.

**Expected shape of integration in the Flutter app (refined after discovery):**

- Two list sources mapped to a common `AvailableList { id, source, name, totalCourseCount }` model.
- List-of-lists fetch concatenates `[all-enrolled synthetic]` + learn.mit.edu `my-lists` response.
- List contents fetch yields a sequence of course ids plus a `supported` flag (MIT Learn native = true, OCW = false).

## Sync Reconciliation

Sync now has an explicit reconciliation step driven by `selected_lists` + per-list contents.

**Algorithm (executed under an existing sync lock):**

1. Resolve the target course set:
   - For each list in `selected_lists`, fetch its courses from the upstream source.
   - Filter out unsupported courses (e.g. OCW).
   - Union all remaining course ids. Deduplicated.
2. Rebuild `course_list_membership` to reflect the new union (insert new pairs, delete pairs no longer present).
3. Compute add set = courses in the new union that aren't yet locally known. Queue them through the existing per-course sync pipeline (compatible with `gradual-sync.md` semantics).
4. Compute drop set = locally-known courses whose membership count is now zero.
5. **Delete-cascade** for every course in the drop set:
   - Cancel any in-flight downloads for the course.
   - Delete all video files and any HLS/MP4 artifacts on disk.
   - Delete all course cache rows (course metadata, sections, sequences, verticals, xblocks, transcripts).
   - Delete all progress rows (watch positions, completion) for the course.
   - Delete downloads feature records associated with the course.
   - Delete the course row itself.
   - No user confirmation at any point.

**Triggers for reconciliation sync:**

- Saving a selection change in settings.
- Normal periodic / pull-to-refresh sync.
- First launch after onboarding completes.

**In-flight download handling:** cancel immediately on drop. No grace period. Partial files are removed as part of delete-cascade.

**List deleted upstream:** treated as a regular reconciliation. The list's courses that aren't referenced by any remaining selected list are deleted silently. Selected-list row for the deleted list is removed from `selected_lists` on discovery (fetch returns 404 or list is absent from `my-lists` response).

## UI Specifications

### List picker (shared between onboarding step 3 and settings)

- **Row content:** list name + secondary line "N courses" (total count, all types, per user's choice).
- **"All enrolled" row:** pinned first, visually distinct (e.g. small system/institutional badge or separator) so it reads as a system list, not a custom one. Otherwise same row layout.
- **Toggle:** leading or trailing checkbox; multi-select.
- **No expandable previews in v1.** (Course-list preview inside a list is out of scope; total count is the only preview signal.)
- **No "Select all" shortcut.**
- **OCW handling at picker level:** lists whose total count includes OCW are shown with their real total count; individual OCW courses are never listed inside the app and never sync. (The selection picker does not drill into individual courses.)

### Onboarding wizard step 3

- Primary CTA: "Continue", disabled until ≥1 list selected.
- Secondary: back button returns to login (re-auth required to proceed again).
- Empty state copy: "No lists found — enroll in a course or create a list at MIT Learn." with "Open MIT Learn" deep-link button.

### Settings → Courses screen

- Full-screen page.
- Top hint: "Manage your enrolled courses and lists at MIT Learn." + compact "Open MIT Learn" button (launches `https://learn.mit.edu/dashboard/my-lists` in browser).
- List picker, pre-toggled to current selection.
- App bar: leading back (discard), trailing primary "Save" (commit + trigger sync).
- Pull-to-refresh re-fetches list-of-lists (not sync).
- Re-auth prompt appears inline if the refresh gets a 401-ish result; persisted cached list remains visible behind the prompt.

### Sync progress

No new UI. The existing sync indicator on the home screen covers first-sync and reconciliation-triggered syncs alike. Deletion is fast enough to be covered by the same indicator.

## Error Handling

- **Playlist fetch fails (network):** show cached `available_lists` row; the picker remains functional; a toast indicates "Couldn't refresh lists."
- **Playlist fetch fails (auth):** show cached list + inline re-auth prompt. User completes login, then the fetch retries automatically.
- **Selected list 404 upstream:** silently drop that row from `selected_lists`; reconciliation handles the rest.
- **List contents fetch fails during reconciliation:** keep existing membership for that list (no-op for that list); surface the sync failure via the existing sync error path. No partial deletes for lists whose fetch failed.
- **Delete-cascade fails mid-course (disk error, etc.):** mark the course as "pending delete" and retry on next sync. Never leave orphaned video files without a matching course row; prefer deleting the row last after files succeed.
- **User has no enrolled and no custom lists (empty state):** handled in UI with block + deep link (see User Flows).

## Migration Plan (existing users)

- On first launch after update, if `selected_lists` is empty AND the app has any locally-synced courses, synthesize a single row: `(list_id = "all-enrolled", source = enrolled, name = "All enrolled")`.
- No UI. Behavior unchanged for existing users.
- New installs follow the onboarding wizard as described.

## Testing Strategy

Unit tests for reconciliation logic are the required scope.

- In-memory Drift setup covering:
  - Ref-counted add/remove across multiple selected lists.
  - Course in one list → remove list → course deleted.
  - Course in two lists → remove one → course retained.
  - Course removed upstream from all selected lists → course deleted.
  - Course transitions from unsupported to supported (if ever) → added.
  - Upstream list 404 → row pruned, cascades.
- Cascade tests: verify videos, progress rows, course cache rows, downloads records all disappear when a course is dropped.
- In-flight download cancel on drop.

Widget / integration tests are not required for v1 but are allowed if small. No fixture-based end-to-end integration test is in scope.

## Analytics

Events added (aligning with `basic-analytics.md` stack):

- `onboarding_list_selection_completed` — on wizard step 3 Continue. Properties: `list_count`, `has_all_enrolled` (bool), `has_my_lists` (bool).
- `settings_list_selection_changed` — on Save in settings. Properties: diff summary — `lists_added`, `lists_removed`, `new_list_count`.

No per-course add/remove events in v1.

## Key Files Reference

Files expected to be added or modified. Paths are best-effort pointers; structure may shift during implementation.

### Added

- `python-tools/mitx-client/` — new commands + docs for learn.mit.edu playlist discovery (extends existing tool).
- `captures/` — new mitmproxy capture(s) for learn.mit.edu playlist flows.
- `dart/app/lib/features/courses/models/available_list.dart`
- `dart/app/lib/features/courses/providers/available_lists_provider.dart`
- `dart/app/lib/features/courses/providers/selected_lists_provider.dart`
- `dart/app/lib/features/onboarding/screens/list_selection_step.dart`
- `dart/app/lib/features/settings/screens/courses_screen.dart`
- `dart/app/lib/features/courses/widgets/list_picker.dart`
- Drift migration adding `selected_lists`, `available_lists`, `course_list_membership` tables.

### Modified

- `dart/app/lib/features/sync/providers/sync_controller.dart` — wire in reconciliation step; delete-cascade of courses dropped from the union.
- `dart/app/lib/features/sync/models/course_sync_state.dart` — any fields needed for reconciliation bookkeeping.
- `dart/app/lib/features/courses/providers/enrollments_provider.dart` — becomes one source among several for the unified list contents pipeline.
- `dart/app/lib/features/onboarding/` — wire wizard step 3 after login, after existing disclosure modal; route to home only after selection saved.
- `dart/app/lib/features/settings/screens/settings_screen.dart` — add "Courses" entry.
- `dart/app/lib/features/downloads/` — expose a "cancel + delete all course artifacts" entry point used by delete-cascade.
- Existing adjacent specs touched: `app-onboarding.md` (flow now continues into wizard), `app-online-course-sync.md` (sync target changes from "all enrolled" to the union), `gradual-sync.md` (compatible — reconciliation chooses *which* courses to sync; gradual-sync governs *how* each course is synced).

## Implementation Notes

**Implemented**: April 2026.

Shipped in two coordinated changes:

1. **Phase A — MIT Learn API discovery** (commit `56a6ce4`): Extended `python-tools/mitx-client/` with a stage-4 SSO handshake against `api.learn.mit.edu` and two new CLI commands (`list-playlists`, `dump-playlist`). Documented the `/api/v1/userlists/` + `/api/v1/userlists/{id}/items/` endpoints and the `resource.platform.code == "mitxonline"` supported-course filter in `python-tools/mitx-client/CLAUDE.md`.

2. **Phase B — Flutter implementation**: Drift schema v6 → v7 adding three tables (user state `selected_lists`, cache `available_lists`, user state `course_list_memberships`); `DioClient` gains a `learnApi` instance with its own lazy SSO refresh (`ensureLearnApiSession`); sync reconciliation in `sync_controller.dart` computes the target union (intersected with enrollments, filtered to mitxonline platform), rebuilds memberships per list, and delete-cascades dropped courses through the existing `VideoDownloadManager.deleteScope` plus new DAO `deleteCourseCache`; router redirects authenticated users without a selection to a new `/onboarding/list-selection` wizard step; `/settings/courses` lets users edit the selection later with Save-triggers-sync semantics; the home screen now watches `activeEnrollmentsProvider` which filters by membership so dropped courses vanish from UI as soon as reconciliation commits; a legacy migration provider seeds the "all-enrolled" row for upgraders.

Reconciliation logic is covered by in-memory Drift unit tests in `dart/app/test/course_list_reconciliation_test.dart` (ref-counted union, drop detection, cascade, migration seed behavior). `fvm flutter analyze` is clean.

**Deviations from spec:**

- Mapping custom-list items to Open edX courseware ids relies on `resource.runs[*].courseware_id` intersected with the user's enrolled run ids — the spec left this open pending Phase A discovery. The user's test lists contained only OCW items so this path is documented but hasn't been empirically verified against a mitxonline-platform list item end-to-end.
- The home screen filter (`activeEnrollmentsProvider`) is an addition not explicitly called out in the spec, needed to honor the "removed from the app" requirement for courses that are still enrolled upstream but outside the selection.
- Pre-existing `test/widget_test.dart` is broken on `main` and remains broken — unrelated to this change.
