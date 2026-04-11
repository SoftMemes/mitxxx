# App Online Course Sync Specification

> **Version**: 2.1 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-11

## Overview

Building on the app-bootstrap spec, implement the online course browsing flows for MITxxx. Users sign in via WebView OAuth, browse their enrolled courses in a 3-level hierarchy (Course List, Course Outline, Content), and view video/HTML/problem blocks. All API data is cached in Drift for offline access using a read-through pattern with pull-to-refresh.

## Screens & Navigation

| Screen | Route | Purpose |
|---|---|---|
| Login | `/login` | WebView OAuth sign-in |
| Course List | `/home` | Enrolled courses, pull-to-refresh |
| Course Outline | `/course/:courseId` | Sections (sticky headers) with sequences listed flat |
| Content | `/course/:courseId/sequence/:seqId` | Scrollable verticals — video player, HTML WebView, problem stubs |
| Settings | `/settings` | Sign out, about info |

### Navigation Flow

- **Top-level**: Course List is the home screen. Settings is accessible via a gear icon in the top-right app bar (no bottom nav bar in v1).
- **Drill-down**: Course List -> Course Outline -> Content. Standard back navigation via app bar back button.
- **Router redirect**: Splash checks auth state -> `/login` if unauthenticated, `/home` if authenticated.

### Course List Screen

- Cards showing: course title, course number (e.g. `24.09x`), and run dates (start - end).
- Pull-to-refresh re-fetches enrollments from the API.
- Tap a card to navigate to Course Outline.
- **Enrollment filter**: Show active enrollments only (where `end_date` is null or in the future). Completed/past courses are excluded in v1.

### Course Outline Screen

- App bar title: course title (truncated if long).
- Flat scrollable list with **sticky section headers** (non-interactive dividers, always expanded).
- Each row under a section header is a sequence. Tap to navigate to Content screen.
- Pull-to-refresh re-fetches the outline.

### Content Screen

- App bar title: sequence title.
- Scrollable vertical list of blocks within the sequence.
- Each vertical is fetched and its blocks are rendered inline (video, HTML, problem).
- Pull-to-refresh re-fetches the sequence and its verticals.

## Auth Flow

### Sign In (WebView OAuth)

1. Show a `webview_flutter` WebView pointed at `https://mitxonline.mit.edu/login/`.
2. The user completes the Keycloak SSO flow entirely within the WebView (username step, password step, redirects).
3. Monitor WebView navigation. When the URL lands back on `mitxonline.mit.edu` with a path indicating success (e.g. `/` or `/dashboard`), extract all cookies from the WebView's cookie store.
4. Copy cookies into the Dio `CookieJar` (specifically `session` on `mitxonline.mit.edu`).
5. Trigger the LMS OAuth handshake programmatically via Dio: `GET https://courses.learn.mit.edu/auth/login/ol-oauth2/?auth_entry=login` with redirects followed. This establishes LMS session cookies (`mitxonline-production-edx-lms-sessionid`, JWT cookies).
6. Verify auth by calling `GET /api/v0/users/current_user/` and checking `is_authenticated`.
7. Persist the cookie jar to secure storage (`flutter_secure_storage`).
8. Navigate to `/home`.

### Cookie Sharing with HTML WebViews

When rendering xblock HTML content in an in-app WebView, the WebView needs LMS session cookies to load assets (images, CSS, MathJax from CDN). Strategy:

- Before loading xblock HTML into a content WebView, inject the LMS cookies from the Dio `CookieJar` into the platform WebView cookie manager (`WebViewCookieManager` from `webview_flutter`).
- This only needs to happen once after auth (or after silent re-auth), not per WebView instance.

### Silent Re-auth on 401

1. A Dio interceptor catches 401 responses.
2. First attempt: replay the LMS OAuth handshake (`GET /auth/login/ol-oauth2/`) since the mitxonline session cookie may still be valid.
3. If that also fails (mitxonline session expired): show the login WebView screen again.
4. On success, retry the original failed request.

### Sign Out

1. Clear the Dio `CookieJar`.
2. Clear WebView cookies via `WebViewCookieManager.clearCookies()`.
3. Delete all data from Drift database (full wipe -- all tables).
4. Clear any persisted cookies in `flutter_secure_storage`.
5. Navigate to `/login`.

## Cache Strategy

### Read-Through Cache

All API responses are cached in Drift. The read flow for every screen:

1. Check Drift for cached data.
2. If cached data exists, display it immediately.
3. In the background, fetch fresh data from the API.
4. On success, update Drift and refresh the UI.
5. On failure (network error), keep showing cached data silently (no error banner).

### Pull-to-Refresh

- Pull-to-refresh forces a network fetch for the **current screen's data only** (not the whole tree).
- On success, Drift is updated and UI refreshes.
- On failure, show a brief snackbar error ("Could not refresh") but keep existing cached data.

### Offline / No Cache

- If no cached data exists **and** the network request fails, show an error empty state with a retry button.
- If cached data exists, always show it. No staleness banners or indicators in v1.

### Cache Scope per Screen

| Screen | What is cached |
|---|---|
| Course List | Enrollments list (single row, JSON blob) |
| Course Outline | Course outline per course_id |
| Content | Sequence detail per block_id, xblock content per vertical block_id |

## API Mapping

| Screen | API Endpoint(s) | Host |
|---|---|---|
| Auth check | `GET /api/v0/users/current_user/` | mitxonline |
| LMS OAuth | `GET /auth/login/ol-oauth2/?auth_entry=login` | LMS |
| Course List | `GET /api/v1/enrollments/` | mitxonline |
| Course Outline | `GET /api/learning_sequences/v1/course_outline/{course_id}` | LMS |
| Content (sequence) | `GET /api/courseware/sequence/{block_id}` | LMS |
| Content (vertical) | `GET /xblock/{block_id}` | LMS |
| CSRF token | `GET /csrf/api/v1/token` | LMS |

## Block Type Rendering

| Block Type | Rendering | Details |
|---|---|---|
| **Video** | Inline `video_player` widget | Play MP4 from CloudFront CDN URL (extracted from xblock `data-metadata` JSON). No auth needed for video URLs. Tap to toggle fullscreen. On-demand streaming, no pre-download in v1. |
| **HTML** | In-app WebView | Load sanitized xblock HTML into a `webview_flutter` instance with LMS cookies injected. Full CSS and MathJax rendering. WebView height auto-sized to content. |
| **Problem** | Read-only card | Show problem title/text if available. Display a note: "Complete problems on the full MITx site." No interaction in v1. |
| **Other/Unknown** | Placeholder card | Gray card with block type label. Non-interactive. |

### Video Player Details

- Use `video_player` package for inline MP4 playback.
- Extract video URL from xblock HTML: parse `data-metadata` attribute on elements, decode JSON, use first `sources[]` entry ending in `.mp4`.
- Player sits inline in the content scroll view. Tap the player to enter fullscreen.
- No download/offline video in v1 -- streaming only.

### HTML WebView Details

- Each HTML block gets its own `WebView` widget.
- Load content via `loadHtmlString()` with a base URL of `https://courses.learn.mit.edu` so relative asset URLs resolve.
- Inject a `<script>` tag for MathJax CDN if not already present in the HTML.
- Disable navigation within the WebView (intercept link taps and open in external browser).
- Auto-size: use JavaScript to measure `document.body.scrollHeight` and set the WebView widget height accordingly.

## Drift Schema Additions

Add the following tables to `app_database.dart`. Bump `schemaVersion` to 2.

### Table: `cached_enrollments`

| Column | Type | Notes |
|---|---|---|
| `id` | integer, primary key | Always 1 (singleton row) |
| `data` | text | JSON-encoded list of enrollments |
| `cached_at` | dateTime | When cached |

### Table: `cached_outlines`

| Column | Type | Notes |
|---|---|---|
| `course_id` | text, primary key | e.g. `course-v1:MITxT+24.09x+1T2025` |
| `data` | text | JSON-encoded course outline |
| `cached_at` | dateTime | When cached |

### Table: `cached_sequences`

| Column | Type | Notes |
|---|---|---|
| `block_id` | text, primary key | Sequence block ID |
| `data` | text | JSON-encoded sequence detail (items list) |
| `cached_at` | dateTime | When cached |

### Table: `cached_xblocks`

| Column | Type | Notes |
|---|---|---|
| `block_id` | text, primary key | Vertical block ID |
| `data` | text | JSON-encoded parsed xblock content (videos, HTML) |
| `cached_at` | dateTime | When cached |

### Design Notes

- The schema mirrors the web version's Dexie cache: one table per API response type, keyed by the natural ID, storing the full JSON response.
- No normalized course/section/sequence tables in v1. The cache is a simple key-value store per endpoint. This keeps implementation simple and aligns with the read-through pattern.
- If a future spec adds offline video downloads or progress tracking, new tables will be added at that point.

## Error Handling

| Scenario | Behavior |
|---|---|
| **401 Unauthorized** | Dio interceptor: attempt silent LMS re-auth. If that fails, redirect to login screen. |
| **Network error (cached data exists)** | Show cached data. No error indicator. Background fetch silently fails. |
| **Network error (no cache)** | Show centered error state: "Could not load [courses/outline/content]" with a Retry button. |
| **Pull-to-refresh fails** | Snackbar: "Could not refresh. Showing cached data." Keep existing data. |
| **xblock parse error** | Show a fallback card: "Content could not be displayed" for that block. Other blocks render normally. |
| **Video load error** | Show error state in the video player area with a retry button. |

## Key Files to Create / Modify

### New Files

```
app/lib/
  core/
    network/auth_interceptor.dart        # 401 interceptor, silent re-auth logic
    storage/tables/                       # Drift table definitions
      cached_enrollments.dart
      cached_outlines.dart
      cached_sequences.dart
      cached_xblocks.dart
  features/
    auth/
      providers/auth_provider.dart        # Auth state (cookie jar, login/logout, is-authenticated)
      screens/login_screen.dart           # (replace placeholder) WebView OAuth screen
    courses/
      models/enrollment.dart              # Enrollment, CourseRun freezed models
      models/course_outline.dart          # Section, CourseOutline freezed models
      models/sequence.dart                # SequenceItem, SequenceDetail freezed models
      models/xblock_content.dart          # ParsedVideoBlock, XBlockContent freezed models
      providers/enrollment_provider.dart  # Fetch + cache enrollments
      providers/outline_provider.dart     # Fetch + cache course outline
      providers/sequence_provider.dart    # Fetch + cache sequence detail
      providers/xblock_provider.dart      # Fetch + parse + cache xblock content
      screens/home_screen.dart            # (replace placeholder) Course list with cards
      screens/course_outline_screen.dart  # Outline with sticky section headers
      screens/content_screen.dart         # Scrollable block content
      widgets/course_card.dart            # Course list card widget
      widgets/video_block.dart            # Inline video player widget
      widgets/html_block.dart             # WebView for HTML content
      widgets/problem_block.dart          # Read-only problem stub
```

### Modified Files

| File | Changes |
|---|---|
| `app/lib/core/storage/app_database.dart` | Add table imports, register 4 new tables, bump schema to v2 |
| `app/lib/core/router/app_router.dart` | Add `/course/:courseId` and `/course/:courseId/sequence/:seqId` routes, wire auth redirect to provider |
| `app/lib/core/network/dio_client.dart` | Add auth interceptor, expose method to inject cookies from WebView |
| `app/lib/main.dart` | Initialize cookie jar from secure storage on startup |
| `app/pubspec.yaml` | Add `webview_flutter`, `video_player` dependencies |

### New Dependencies

| Package | Purpose |
|---|---|
| `webview_flutter` | OAuth login WebView + HTML block rendering |
| `video_player` | Inline MP4 video playback |

## Decisions Made

The following were not explicitly answered during refinement but are resolved here with reasonable defaults:

1. **Enrollment filter**: Active only (end_date null or future). Past courses excluded in v1.
2. **App navigation**: No bottom nav bar. Settings accessible from gear icon in the Course List app bar. Simple and minimal.
3. **Cache invalidation on pull-to-refresh**: Current screen only, not the full tree.
4. **WebView cookie sharing**: Inject Dio cookie jar cookies into platform WebView cookie manager after auth and after any silent re-auth.
5. **Drift schema style**: JSON blob cache (one table per endpoint) rather than fully normalized tables. Matches the web version's approach and keeps v1 simple.

## Implementation Notes

**Implemented**: April 2026

**Key Files Created**:
- `lib/features/auth/models/user.dart` — User freezed model
- `lib/features/courses/models/enrollment.dart` — Enrollment + CourseRun models
- `lib/features/courses/models/outline.dart` — CourseOutline + Section models
- `lib/features/courses/models/sequence.dart` — SequenceDetail + SequenceItem models
- `lib/features/courses/models/xblock_content.dart` — XBlockContent + ParsedVideoBlock models
- `lib/core/network/dio_client_provider.dart` — DioClient Riverpod provider
- `lib/core/storage/database_provider.dart` — AppDatabase Riverpod provider
- `lib/features/auth/providers/auth_provider.dart` — Auth state notifier (session check, sign-in, sign-out, 401 interceptor wiring)
- `lib/features/courses/providers/enrollments_provider.dart` — Read-through cache for course list
- `lib/features/courses/providers/outline_provider.dart` — Read-through cache for course outline
- `lib/features/courses/providers/sequence_provider.dart` — Read-through cache for sequence detail
- `lib/features/courses/providers/xblock_provider.dart` — Read-through cache + HTML parse for xblock content
- `lib/features/courses/utils/xblock_parser.dart` — Port of xblock-parser.ts: regex + HTML decode + JSON parse
- `lib/features/courses/screens/course_outline_screen.dart` — Outline screen with sticky section headers
- `lib/features/courses/screens/content_screen.dart` — Content screen rendering video/HTML/problem blocks
- `lib/features/courses/widgets/video_block.dart` — Inline video_player widget
- `lib/features/courses/widgets/html_block.dart` — WebView HTML renderer with MathJax injection
- `lib/features/courses/widgets/problem_block.dart` — Read-only problem stub card
- `build.yaml` — Configures json_serializable to use snake_case field renaming globally

**Key Files Modified**:
- `pubspec.yaml` — Added webview_flutter, video_player, html_unescape
- `lib/core/storage/app_database.dart` — 4 cache tables (enrollments, outlines, sequences, xblocks), schemaVersion 2
- `lib/core/network/dio_client.dart` — Added addAuthInterceptor() for 401 silent re-auth
- `lib/core/router/app_router.dart` — Converted to Riverpod provider, added course routes, auth-aware redirect
- `lib/main.dart` — WidgetsFlutterBinding.ensureInitialized(), ConsumerWidget reading router provider
- `lib/features/auth/screens/login_screen.dart` — WebView OAuth flow with JS cookie extraction
- `lib/features/courses/screens/home_screen.dart` — Real course list with read-through cache
- `lib/features/settings/screens/settings_screen.dart` — Sign out with confirmation dialog

**Deviations from Spec**:
- Cookie extraction from WebView uses JavaScript `document.cookie` rather than a platform-level cookie API (webview_flutter 4.x has no `getCookies` method). httpOnly cookies from Keycloak are not accessible via JS. The programmatic LMS OAuth step in `onLoginComplete()` establishes the JWT cookies via Dio directly, which covers the critical LMS auth path.
- Auth interceptor is attached in `AuthProvider.build()` (not in `dioClientProvider`) to avoid a circular provider dependency.
- The 401 interceptor guard (`_authInterceptorAttached`) prevents duplicate interceptors if the auth provider rebuilds.
