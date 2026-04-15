# Basic Analytics Specification

> **Version**: 1.2 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-15

## Description

Using Firebase Analytics (Google Analytics for Firebase), add tracking events for core actions in the MITxxx Flutter app so we can understand real-world usage: how often the app is opened, how reliably sync/download works, which courses are viewed, and how users interact with video lectures.

Firebase Analytics is already a dependency (`firebase_analytics: ^11.3.6`) and `Firebase.initializeApp` is wired up via `firebase_options.dart`. This spec defines the event catalog, parameters, naming convention, and implementation architecture.

> **Note on open questions:** the `AskUserQuestion` tool was unavailable during refinement. The author made opinionated defaults based on Firebase best practice and the existing codebase layout (`lib/core`, `lib/features/{auth,courses,downloads,player,settings,sync}`). Each default is flagged in the "Flagged defaults" section at the bottom. The user should skim and override anything they disagree with before implementation starts.

---

## Event Catalog

All events use **snake_case** and are **not** namespaced with an `mitx_` prefix — Firebase's reserved prefixes are `firebase_`, `google_`, `ga_`, so collisions are not a concern, and shorter names are easier to read in GA4 reports. Events reuse standard Firebase names (`app_open`, `login`, `screen_view`) where semantically appropriate so built-in GA4 reports light up for free.

> **Convention:** IDs are passed as-is (the Open edX full strings, e.g. `course-v1:MITxT+24.09x+1T2025`). GA4 event-parameter values are capped at 100 chars — all MITx IDs fit comfortably.

### App-level events

| Event name | Trigger | Parameters |
|---|---|---|
| `app_open` | `main()` after Firebase init, once per cold start | `platform` (ios/android), `app_version` (string), `is_first_open` (bool — first launch after install) |
| `login_success` | OAuth flow completes, JWT cookies set | `method` (`keycloak_sso`) |
| `login_failure` | OAuth flow returns error or user cancels | `reason` (enum: `cancelled`, `network`, `credentials`, `unknown`), `stage` (enum: `mitxonline`, `keycloak`, `lms`) |
| `logout` | User taps logout in settings | _(none)_ |
| `sync_start` | Any sync kicked off | `scope` (`all_courses` \| `course`), `course_id` (string, only when scope=course), `trigger` (`manual` \| `auto_on_open` \| `pull_to_refresh`) |
| `sync_complete` | Sync finishes successfully | `scope`, `course_id`, `duration_ms` (int), `items_synced` (int — sequences+verticals touched) |
| `sync_failure` | Sync aborts with an error | `scope`, `course_id`, `duration_ms`, `stage` (`enrollments` \| `outline` \| `xblock` \| `transcripts`), `error_kind` (`network` \| `auth` \| `server` \| `parse` \| `unknown`) |
| `download_start` | Download job enqueued | `scope` (`course` \| `section` \| `video`), `course_id`, `block_id` (nullable), `video_count` (int), `total_bytes_estimate` (int, nullable) |
| `download_complete` | All files in the job finished | `scope`, `course_id`, `block_id`, `duration_ms`, `bytes_downloaded` (int), `video_count` |
| `download_failure` | Job aborted / cancelled / errored | `scope`, `course_id`, `block_id`, `error_kind` (`network` \| `storage_full` \| `cancelled` \| `unknown`), `videos_completed` (int), `videos_total` (int) |

### Course-level events

| Event name | Trigger | Parameters |
|---|---|---|
| `course_view` | Course detail screen opened | `course_id`, `course_run` (string), `source` (`course_list` \| `deep_link` \| `resume`) |
| `section_open` | A `sequential`/`chapter` is expanded or navigated into | `course_id`, `block_id` (the section), `section_index` (int) |
| `section_play` | User taps "play" from a section header (plays first/next video in section) | `course_id`, `block_id` (the section), `video_block_id` (the video it resolves to) |

### In-course video interaction events

| Event name | Trigger | Parameters |
|---|---|---|
| `video_play` | `video_player` transitions paused→playing (first play and resumes) | `course_id`, `video_block_id`, `position_s` (int, seconds), `duration_s` (int), `is_resume` (bool) |
| `video_pause` | Playing→paused **excluding** transitions caused by scrubbing | `course_id`, `video_block_id`, `position_s`, `duration_s` |
| `video_complete` | Playback reaches end (≥ 95% of duration) | `course_id`, `video_block_id`, `duration_s` |
| `video_scrub` | Fired on **scrub-end only** (not continuously) to avoid event flooding | `course_id`, `video_block_id`, `from_position_s` (int), `to_position_s` (int), `duration_s` |

### User properties (set once per session, updated on change)

| Property | Type | Source |
|---|---|---|
| `enrollment_count` | int | Count of `GET /api/v1/enrollments/` results |
| `downloaded_course_count` | int | Count of courses with any offline content |
| `app_theme` | string | `light` / `dark` / `system` from settings |
| `analytics_opted_in` | bool | See Privacy section |

> **Deliberately NOT set:** email, name, MITx username, Keycloak subject. See Privacy section.

---

## Naming Convention

- **Case:** `snake_case` for both event names and parameter names.
- **No vendor prefix:** event names are bare (`app_open`, not `mitx_app_open`).
- **Reuse GA4 standard names** where the semantic meaning matches (`app_open`, `login`). We emit `login_success` / `login_failure` instead of plain `login` so funnels distinguish outcomes (GA4's built-in `login` does not).
- **Verb-noun or noun-verb consistency:** lifecycle pairs use `<noun>_start` / `<noun>_complete` / `<noun>_failure` (sync, download). User-driven one-shots use `<noun>_<verb>` (`video_play`, `section_open`).
- **Parameter ID fields** always use the full Open edX format strings and the names `course_id`, `block_id`, `video_block_id`.

---

## User Identity

- We call `FirebaseAnalytics.instance.setUserId(...)` with the **device advertising ID** (IDFA on iOS, GAID on Android), retrieved via the `advertising_id` package. This is a stable, per-install anonymous identifier that survives logout and does not require a logged-in user — ideal for tracking pre-login funnels.
- The advertising ID is fetched once at app start and cached. If the user has limited ad tracking (iOS ATT denied or Android opt-out), `setUserId(null)` is used and session stitching degrades gracefully to Firebase's own anonymous instance ID.
- `setUserId` is **not** reset on logout — the advertising ID is device-scoped, not account-scoped.
- User properties from the table above are set via `setUserProperty` at app launch and refreshed whenever the underlying value changes.

---

## Implementation Architecture

### Centralized analytics service

A single `AnalyticsService` class in `lib/core/analytics/analytics_service.dart`, exposed via a Riverpod provider. All analytics calls route through it — **no inline `FirebaseAnalytics.instance` calls anywhere else in the codebase** (enforced via code review).

The service exposes one typed method per event (`logAppOpen()`, `logVideoPlay(...)`, `logSyncFailure(...)`, etc.) so:
- parameter names/types are centrally defined and refactor-safe,
- all events flow through a single choke point for opt-out, debug logging, and PII scrubbing,
- adding a new event requires a new method (visible in diffs).

Internally the service calls `FirebaseAnalytics.instance.logEvent(name, parameters)`.

### Debug mode

- When `kDebugMode` is true, every event is also emitted to the existing `logging` package via `core/logging.dart`, using a dedicated `Analytics` logger name at `INFO` level, with the event name and full parameter map. This lets developers see events in the Flutter console without needing Firebase DebugView.
- In release builds, debug logging is compiled out.

### Opt-out

- A settings toggle "Share usage analytics" (default: **on**) lives under `lib/features/settings/`.
- When off, `AnalyticsService` calls `FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(false)` and short-circuits all `logEvent` calls locally as defense-in-depth.
- Toggle state is persisted via `flutter_secure_storage` (already a dep) under key `analytics_opted_in`.
- Suggested settings copy: "Help improve MITxxx by sharing anonymous usage data. No course content, names, or emails are ever sent." Final wording finalized during implementation.

### Scrubbing specifics

- `video_scrub` fires **only on scrub-end** (when the user releases the seek handle), not on every position tick.
- Both `from_position_s` and `to_position_s` are recorded.
- Programmatic seeks caused by "resume from last position" do **not** fire `video_scrub`; they fire `video_play` with `is_resume=true` instead.
- A pause caused purely by the scrub interaction (Chewie's default behavior) is suppressed from emitting `video_pause`.

### Download granularity ("per level")

The original spec's "per level" is resolved to three scopes, tracked via the `scope` parameter on download events:
- `scope=course` — user taps "Download entire course".
- `scope=section` — user taps download on a section/sequential.
- `scope=video` — user taps download on an individual video block.

All three emit `download_start`, then exactly one `download_complete` **or** `download_failure` once the aggregate job settles.

### Sync events

- Success and failure are **separate** events (`sync_complete` vs `sync_failure`) so conversion/funnel reports work without parameter filtering.
- `scope` distinguishes app-level (`all_courses`) from per-course sync.
- `stage` on failures pinpoints where in the pipeline we broke.

---

## Privacy & Compliance

- **No PII in event parameters or user properties.** Specifically banned: email, display name, MITx username, Keycloak subject, full name, institution.
- User ID is the device advertising ID (IDFA/GAID) — a resettable, device-scoped anonymous identifier. Not linked to the MITx account.
- Course IDs and block IDs are **not** considered PII — they are public catalog identifiers, used as-is.
- Opt-out respected app-wide via the settings toggle above.
- Crashlytics (already a dep) is a separate system; its PII policy is out of scope for this spec but follows the same "no PII" rule by default.
- A brief privacy note is added to the onboarding flow and/or settings screen explaining what's collected.

---

## Testing Strategy

- **Manual verification:** use Firebase DebugView during development. Enable via `adb shell setprop debug.firebase.analytics.app <bundle>` on Android and `-FIRDebugEnabled` launch arg on iOS. A short section in `dart/app/README.md` documents this.
- **Debug console logging** (see Implementation Architecture) provides instant local feedback without Firebase round-trip.
- **Unit tests:** the `AnalyticsService` is unit-tested by injecting a fake `FirebaseAnalytics` (via a thin interface) and asserting each `logX()` method emits the expected name+params. One test per event method.
- **Widget/integration tests** do **not** assert on analytics calls (too brittle). A single smoke test verifies the `AnalyticsService` provider is wired up and no-ops cleanly when opted out.
- **No automated E2E checks against Firebase** — the cost/flakiness isn't worth it for a basic analytics spec.

---

## Key Files

**New files:**
- `dart/app/lib/core/analytics/analytics_service.dart` — the centralized service and Riverpod provider.
- `dart/app/lib/core/analytics/analytics_events.dart` — event name constants and parameter-key constants (single source of truth).
- `dart/app/lib/core/analytics/advertising_id_provider.dart` — fetches and caches the advertising ID at startup, falls back to null gracefully.
- `dart/app/test/core/analytics/analytics_service_test.dart` — unit tests.

**Modified files:**
- `dart/app/pubspec.yaml` — add `advertising_id` package.
- `dart/app/lib/main.dart` — emit `app_open` after Firebase init; wire provider; apply opt-out preference pre-init.
- `dart/app/lib/features/auth/**` — emit `login_success`, `login_failure`, `logout`; call `setUserId` on auth state changes.
- `dart/app/lib/features/sync/**` — emit `sync_start`, `sync_complete`, `sync_failure` at sync entrypoints.
- `dart/app/lib/features/downloads/**` — emit `download_start`, `download_complete`, `download_failure` from the download orchestrator; compute aggregate completion.
- `dart/app/lib/features/courses/**` — emit `course_view`, `section_open`, `section_play` from course detail and section widgets.
- `dart/app/lib/features/player/**` — emit `video_play`, `video_pause`, `video_complete`, `video_scrub` from the Chewie/video_player wrapper; suppress scrub-induced pauses; distinguish resume seeks.
- `dart/app/lib/features/settings/**` — add "Share usage analytics" toggle; persist via `flutter_secure_storage`.
- `dart/app/README.md` — short "Analytics / DebugView" section documenting how to verify locally.

---

## Implementation Notes

**Implemented**: April 2026

**New files:**
- `dart/app/lib/core/analytics/analytics_events.dart` — event name + param key constants
- `dart/app/lib/core/analytics/analytics_preferences.dart` — SharedPreferences-backed opt-in notifier + first-open flag
- `dart/app/lib/core/analytics/advertising_id_provider.dart` — IDFA/GAID provider with graceful null handling
- `dart/app/lib/core/analytics/analytics_service.dart` — central typed service, Riverpod provider, debug logging

**Key deviations from spec:**
- Settings screen had no existing persistence infrastructure; used `shared_preferences` (new dep) instead of `flutter_secure_storage`
- `_SequenceTile.onTap` now serves as both section-open and section-play trigger (play icon button fires both); `logSectionPlay` fires in addition to `logSectionOpen` on the play icon
- `syncAll` accepts an optional `trigger` string param so call sites can pass `kTriggerAuto`/`kTriggerManual`; `syncCourse` called from `syncAll` internally uses `kTriggerManual` as default
- Download job tracking is best-effort: jobs keyed by `blockId ?? courseId`; in the (rare) concurrent multi-scope case, all active jobs advance on every completion event

---

## Resolved decisions

1. **Opt-out default is ON** (analytics enabled by default). ✓
2. **User ID is the device advertising ID** (IDFA/GAID), not tied to the MITx login user. Degrades gracefully to no user ID if ad tracking is limited. ✓
3. **`video_scrub` fires on scrub-end only** (when the user releases the seek handle). ✓
4. **No `mitx_` prefix on event names.** ✓
5. **No automated analytics E2E tests.** ✓
6. **Course/block IDs used as-is** (public catalog identifiers, not PII). ✓
