# Opencourseware Support Specification

> **Version**: 2.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-17

## Description

Building on `course-shortlist-sync.md`, fully support MIT OpenCourseWare (OCW) courses in the app, presented as much as possible in the same way as existing MITx courses.

OCW content looks different from Open edX: there are no xblocks, and each lecture is a single video on the OCW page with a set of downloadable resources (PDFs for lecture notes and slides) beside it. This spec models **one lecture as one video**, reuses the existing single-page `LectureScreen`, and surfaces per-lecture resources as external links below the video inside a synthesized "resources" content tile. The video content and metadata are synced via the same `SyncController` pipeline that handles MITx courses, with per-course-type fetch dispatch.

OCW courses reach the app exclusively via learn.mit.edu lists that the user has already selected through `course-shortlist-sync`. This spec flips the `supported` flag for OCW in that pipeline, so OCW courses that were previously listed-but-unsupported now sync.

---

## Goals

- Enable OCW courses to sync into the app and be browsed/played identically to MITx courses.
- Reuse the existing `LectureScreen`, `VideoDownloadManager`, `SyncController`, and learn.mit.edu list selection instead of building parallel infrastructure.
- Surface `lecture notes` and `lecture slides` PDFs next to the lecture they belong to, matched by name. Unmatched files fall back to a course-level "Resources" section.
- Keep the UI visually identical to MITx courses — no OCW-specific badges or separate sections.

## Non-Goals

- In-app OCW search / browse / URL paste. Discovery happens entirely via learn.mit.edu lists.
- Resource types beyond lecture notes + lecture slides (problem sets, solutions, readings, code, notebooks are deferred).
- YouTube playback. OCW's YouTube embeds are ignored. Lectures that only expose YouTube (no downloadable MP4) are synced but show an inline "not available" state per-lecture.
- Transcripts / subtitles for OCW video.
- Server-side progress tracking for OCW (no upstream exists). No local watch-position restore in v1.
- In-app PDF viewing. Resources are external-browser links.
- Course-run grouping UI. Each OCW run (distinct URL slug) is treated as its own course.
- Migration bells + whistles. Existing shortlist-sync users pick up OCW on the next reconciliation automatically (see Migration).

---

## Discovery Plan

OCW has no documented API and is a disjoint platform from MITx (no auth, no Open edX, different URL space). Discovery work is part of this spec and must complete before Flutter work lands.

### New tool: `python-tools/ocw-client/`

Stand up a new tool directory (separate from `mitx-client/` — platforms don't share code):

- `python-tools/ocw-client/CLAUDE.md` — tool purpose, discovered endpoints / page structure, resource shape, video URL extraction rules.
- `python-tools/ocw-client/client.py` — HTTP client + OCW HTML parser.
- `python-tools/ocw-client/cli.py` — CLI commands:
  - `course <slug>` — fetch + dump a course's outline.
  - `lecture <slug> <lecture-id>` — dump a single lecture's video + resource links.
  - `resources <slug>` — dump all downloadable files associated with a course.
- Shares `python-tools/requirements.txt` with the other tools.

### mitmproxy captures

Record and commit flows under `captures/` for the reference courses below. Capture at least:

1. Course home page.
2. One lecture detail page per course.
3. The "download video" link target (the direct MP4 URL we use for playback).
4. One lecture notes PDF + one lecture slides PDF.

### Reference courses

Used for capture, parser fixtures, and manual QA:

- **18.06 Linear Algebra (Gilbert Strang)** — `ocw:18-06-linear-algebra-spring-2010`.
- **6.006 Intro to Algorithms** — unit-structured outline.
- **8.01 Physics I (Walter Lewin)** — legacy page structure stress test.
- **9.13 The Human Brain (Spring 2019)** — `ocw:9-13-the-human-brain-spring-2019`, user-supplied reference.

### What to document

Each captured endpoint or HTML pattern is written up in `python-tools/ocw-client/CLAUDE.md` with:

- URL / selector.
- Request shape (none — OCW is public GETs).
- Response / extracted fields.
- Video-URL extraction rule (the "download video" link; ignore YouTube).
- Resource extraction rule (file name, URL, inferred type: `lecture-notes` | `lecture-slides`).
- Course-structure extraction (sections / units / lectures).

Only once this tool is landed do Flutter data-layer changes begin.

---

## Course Identity & Entry

### ID format

OCW courses use `ocw:{url-slug}` as their course id, derived from the canonical OCW URL path. Examples:

- `ocw:18-06-linear-algebra-spring-2010`
- `ocw:9-13-the-human-brain-spring-2019`

The `ocw:` prefix disambiguates from Open edX's `course-v1:` IDs so existing downstream code that switches on prefix can dispatch correctly.

### Course runs

Each OCW run is its own course; the slug already encodes term + year. No run grouping, no run dropdown. If the user selects a learn.mit.edu list that contains two runs of the same subject, both sync as separate courses.

### Entry path

OCW courses enter the app **only** via learn.mit.edu lists. `course-shortlist-sync` currently fetches list contents and marks each item with a `supported` flag; items where `supported = false` (OCW) are filtered out before the reconciliation union.

**This spec flips `supported` to `true` for OCW courses.** After landing, OCW courses inside selected lists flow through the existing `selected_lists` → `course_list_membership` → reconciliation pipeline unchanged. The shortlist-sync delete-cascade removes OCW artifacts identically.

No opt-in toggle. No "All OCW" synthetic source. No in-app search.

---

## Data Model

New OCW-specific Drift tables, registered in `app_database.dart`. Bump `schemaVersion` accordingly. Existing MITx tables are untouched.

### Table: `cached_ocw_courses`

| Column | Type | Notes |
|---|---|---|
| `course_id` | TEXT PK | `ocw:{slug}` |
| `title` | TEXT | |
| `course_number` | TEXT | e.g. `18.06` |
| `description` | TEXT | Short description (first paragraph of OCW "About this course") |
| `data` | TEXT | Full JSON course metadata blob (future-proofing) |
| `cached_at` | INTEGER | Epoch ms |

### Table: `cached_ocw_lectures`

| Column | Type | Notes |
|---|---|---|
| `lecture_id` | TEXT PK | `ocw:{slug}/{lecture-slug}` |
| `course_id` | TEXT FK | `cached_ocw_courses.course_id` |
| `section_title` | TEXT | Unit / week / topic label from OCW |
| `section_order` | INTEGER | Section display order |
| `lecture_order` | INTEGER | Display order within section |
| `title` | TEXT | |
| `mp4_url` | TEXT nullable | The "download video" MP4 URL. NULL if only YouTube. |
| `duration_seconds` | INTEGER nullable | If surfaced on the page |
| `cached_at` | INTEGER | Epoch ms |

### Table: `cached_ocw_resources`

| Column | Type | Notes |
|---|---|---|
| `resource_id` | TEXT PK | Synthetic — hash of course_id + url |
| `course_id` | TEXT FK | |
| `lecture_id` | TEXT nullable | FK to `cached_ocw_lectures.lecture_id` if matched; NULL = orphan (course-level) |
| `type` | TEXT | `lecture-notes` \| `lecture-slides` |
| `title` | TEXT | File name / display label |
| `url` | TEXT | Absolute URL to the PDF on ocw.mit.edu |
| `cached_at` | INTEGER | Epoch ms |

### Dart models (freezed)

- `OcwCourse { id, title, courseNumber, description, sections: List<OcwSection> }`
- `OcwSection { title, lectures: List<OcwLecture> }`
- `OcwLecture { id, title, mp4Url?, durationSeconds?, resources: List<OcwResource> }`
- `OcwResource { id, type: OcwResourceType, title, url }`
- `OcwResourceType` enum: `lectureNotes`, `lectureSlides`.

---

## Course Ingestion Pipeline

### Dispatch in `SyncController`

Add per-course-type dispatch. Current controller assumes Open edX; change it to:

1. Look at course id prefix.
2. If `course-v1:` → existing MITx fetcher.
3. If `ocw:` → new `OcwCourseFetcher`.
4. Both fetchers report progress through the same status model; reconciliation, delete-cascade, and gradual-sync queueing are shared.

An explicit `CourseFetcher` interface may be introduced or the dispatch may remain a branch; implementation choice at build time. The user-visible behavior is identical either way.

### OCW course fetch

For each OCW course being synced:

1. Fetch the course home HTML. Parse:
   - Title, course number, short description.
   - Section list (units / weeks / topics) in display order.
   - Lecture list under each section, with per-lecture URL.
2. For each lecture: fetch the lecture detail HTML. Parse:
   - Lecture title.
   - MP4 URL — the "download video" link on the OCW player. **Always use this. Ignore YouTube.** If no download link exists, record `mp4_url = NULL`.
   - Duration if surfaced.
3. Fetch the course resources / downloads page. Parse:
   - All files of type `lecture-notes` or `lecture-slides` (other types ignored).
   - For each file: title, URL, type.
4. Match each resource to a lecture (see Resource Matching below).
5. Write `cached_ocw_courses`, `cached_ocw_lectures`, `cached_ocw_resources` atomically.

### Resource matching

Match every resource to at most one lecture using this algorithm:

1. Extract lecture number from both sides:
   - Lecture title: regex `(?i)lecture\s+(\d+)` → number.
   - Resource title: same regex, plus fallbacks `lec\s*(\d+)`, `(\d+)\.pdf$`.
2. If both sides yield the same number → match.
3. Else, normalize both titles (lowercase, strip punctuation, collapse whitespace). If the resource title starts with the lecture title (or vice-versa) → match.
4. Else → unmatched.

Unmatched resources are persisted with `lecture_id = NULL` and surfaced in a course-level "Resources" section on the course outline screen (see UI).

Matching runs once per sync over the complete resource + lecture set (not incrementally). Changing the matching rules in a future release re-runs on next sync.

### Gradual sync

Mirror `gradual-sync.md` semantics: the OCW fetcher yields per-lecture progress so the sync queue can stream one lecture at a time. Video downloads queue through `VideoDownloadManager` as MP4 URLs become known, identical to MITx.

### URL change detection

For OCW video URLs: same staleness model as MITx. On every course refresh, compare current `mp4_url` values against `DownloadedVideos` rows and mark changed ones as `stale`.

Resource URLs don't get change detection — nothing is downloaded, the URL is just opened in the browser. A re-sync replaces the stored URL and the next tap picks it up.

---

## Sync Reconciliation

No changes to the `selected_lists` / `course_list_membership` reconciliation algorithm in `course-shortlist-sync.md`. Flipping the `supported` flag for OCW is the only integration change: OCW course ids start appearing in the target union.

Delete-cascade for a dropped OCW course deletes, end-to-end:

- All `cached_ocw_resources` rows for that course.
- All `cached_ocw_lectures` rows.
- The `cached_ocw_courses` row.
- All downloaded video files for `mp4_url`s referenced only by lectures in that course (via `DownloadedVideos.courseIds` ref-count, same as MITx).
- All in-flight downloads for those URLs.

No user confirmation.

---

## Playback & Lecture Screen

### Lecture screen reuse

OCW lectures render through the existing `LectureScreen` (`single-page-lecture.md`) with a one-segment stitch:

- `segments: [VerticalSegment]` has a single entry.
- `segment.videoUrl` = local MP4 path if downloaded, else the OCW download-MP4 URL.
- `segment.videoDuration` = cached duration.
- `segment.safeHtmlContent` = **synthesized resource HTML** (see below) — rendered through the same HTML block widget the MITx lectures use, via the existing `sane-html-parsing.md` sanitizer.
- The collapsible content list has one tile containing the resource HTML. No empty placeholder tiles.

Because the stitch is length-1, there is no timeline-section sync and no scrubbing-between-segments behavior — all existing logic in `LecturePlaybackController` handles this trivially.

### Synthesized resource xblock HTML

Generated at read time from the lecture's matched resources. Format (grouped by type):

```html
<h3>Lecture notes</h3>
<ul>
  <li><a href="https://ocw.mit.edu/.../MIT18_06_L14.pdf">Lecture 14 notes (MIT18_06_L14.pdf)</a></li>
</ul>
<h3>Lecture slides</h3>
<ul>
  <li><a href="https://ocw.mit.edu/.../L14_slides.pdf">Lecture 14 slides (L14_slides.pdf)</a></li>
</ul>
```

- Sections are omitted if empty.
- If a lecture has zero matched resources, `safeHtmlContent = ""` and the collapsible tile shows the existing "No additional content for this section." empty state from `sane-html-parsing.md`.
- Links open in the system browser via the existing `url_launcher` path already wired into `HtmlBlock` (no new link-handling code).

### Lectures with no MP4 (YouTube-only)

The lecture row appears in the course outline normally. On entering the lecture screen:

- The video player area shows an inline "Video not available — this lecture is YouTube-only" state with an "Open in browser" button deep-linking to the OCW lecture page.
- The resource tile below still renders.

No offline download for these lectures.

### Offline video

OCW MP4 URLs plug into `VideoDownloadManager` unchanged:

- URL is the primary key in `DownloadedVideos`.
- Download / cancel / resume / stale / retry behavior identical to MITx.
- Local-file-first playback in `LectureScreen` applies identically.
- Course/sequence/vertical-level download buttons from `app-offline-video.md` map as follows for OCW:
  - Course = download all lectures in the course.
  - Section = download all lectures in that section.
  - Lecture = download that one lecture's video.

---

## UI Specifications

### Course list

Identical to the existing card layout. No OCW badge. No separate section. Sorting / filtering behavior unchanged. Card content:

- Title.
- Course number.

### Course outline screen

Identical shell to MITx outline (sticky section headers, flat sequence list under each). Differences for OCW:

- Section headers come from the OCW unit/week structure.
- A leading "About this course" block at the top of the screen shows the short description (if present) — equivalent of the course metadata header the MITx outline already has. If not present, omit cleanly.
- If the course has any unmatched (orphan) resources, append a final synthetic section titled **"Resources"** with one row per orphan resource. Tapping a row opens the URL in the system browser.
- Download button behavior identical to MITx outline.

### Lecture screen

Reuses `LectureScreen` verbatim (see Playback above).

### Settings / list picker

No changes. `course-shortlist-sync`'s settings screen already handles list picking. OCW courses already showed up in list total counts before this spec; with `supported` flipped they now participate in sync.

---

## Auth & Network

- OCW pages are public (no auth required). However, all OCW fetches happen **after** the user has logged into MITx, because OCW courses are discovered via learn.mit.edu lists which require auth.
- OCW HTTP requests go through a Dio instance with no cookie jar attached (public GETs). No CSRF, no JWT.
- Rate limiting: respect any HTTP 429 responses with exponential backoff, same policy as `mitx_api`. Gradual sync already paces requests.
- OCW CDN video URLs are unsigned and downloadable directly (user has confirmed the "download video" link works). No signing / token injection.

---

## Error Handling

| Scenario | Behavior |
|---|---|
| OCW course page fails to parse (structure change) | Keep last-good cached data. Show inline "Couldn't update this course" banner on the course outline. Other courses unaffected. |
| OCW lecture page fetch fails mid-sync | Mark that lecture's sync as failed; retry on next sync. Other lectures in the course proceed. |
| MP4 URL missing (YouTube-only) | Persist `mp4_url = NULL`; lecture screen renders the "not available" state. Not a sync error. |
| MP4 download fails | Existing `VideoDownloadManager` retry + `failed` status. Unchanged. |
| Resource link URL 404 at tap time | `url_launcher` opens the URL; the browser reports the 404. App does not pre-validate URLs. |
| Reconciliation drops an OCW course | Delete-cascade runs (see Sync Reconciliation). Identical to MITx. |
| User goes offline mid-sync | Existing sync pause + resume behavior. Lecture rows already persisted remain viewable/playable to the extent of what's been cached. |

---

## Migration

- Users on `course-shortlist-sync` who have already selected lists containing OCW courses: on the next reconciliation after this spec lands, OCW courses start appearing. No user action, no prompt, no opt-in.
- Users who previously saw OCW courses listed-but-unsupported: these now sync silently. No migration banner.
- No Drift migration of existing MITx data is needed — only the new OCW tables are added.

---

## Testing Strategy

### Parser fixtures (Python)

Commit captured HTML under `python-tools/ocw-client/fixtures/` for each reference course:

- Course home HTML.
- One lecture detail HTML per course.
- Course resources HTML.

Python unit tests assert:

- Outline structure (section count, lecture count, order) per reference course.
- MP4 URL extraction picks the "download video" link, not YouTube.
- Resource extraction keeps only `lecture-notes` + `lecture-slides` types.

### Parser fixtures (Dart)

Mirror the fixtures under `dart/app/test/fixtures/ocw/`. Dart unit tests cover:

- Parsing → model shape for each reference course.
- Synthesized-resource HTML shape: grouping headers, `<ul>`/`<li>`, link count matches matched resources.
- Sanitizer round-trip (resource HTML → `sanitizeXBlockHtml` → unchanged).

### Resource matching unit tests

Dedicated tests for the matcher with adversarial inputs:

- Lecture 1 vs Lecture 10 (off-by-one / prefix collisions).
- Recitations named "Recitation 14" should not match "Lecture 14".
- File name like `L14.pdf` (number only, no "Lecture" keyword).
- Resources with no lecture number → orphaned.
- Duplicate matches: a resource that matches two lectures → prefer lower-distance match; assert deterministic behavior.

### Sync reconciliation tests

Extend existing in-memory Drift tests from `course-shortlist-sync`:

- OCW course appears in a selected list → added to `course_list_membership`, fetched, persisted.
- OCW course removed from list → delete-cascade wipes `cached_ocw_*` rows + downloaded MP4s (unless referenced by another course).
- OCW course + MITx course share a learn.mit.edu list → both sync through their respective fetchers under one sync run.
- OCW course with zero MP4s → lectures persist, no downloads queued, no error surfaced.

### Manual QA on device

Using 18.06, 6.006, 8.01, 9.13:

- Add to a learn.mit.edu list upstream → sync → course appears identically to MITx.
- Open a lecture → video plays from CDN → tap download button → plays from local file after download.
- Open a lecture with matched notes + slides → resource HTML tile shows both sections with working links that open the system browser.
- Open a lecture with no matched resources → empty-content placeholder.
- Open a course with orphan resources → course outline ends with a "Resources" section listing them.
- Remove the list containing an OCW course → course + videos disappear silently.
- Force-kill network mid-video download → resumes on reconnect (platform background download).

Integration tests against live ocw.mit.edu are **not** in scope.

---

## Key Files Reference

Paths are best-effort; structure may shift during implementation.

### Added

**Python tooling + captures:**

- `python-tools/ocw-client/` — new tool directory.
  - `CLAUDE.md`
  - `client.py`
  - `cli.py`
  - `fixtures/` (committed HTML samples + expected JSON)
  - Tests under `tests/`
- `captures/` — new mitmproxy flows for ocw.mit.edu reference courses.

**Dart (Flutter app):**

- `dart/app/lib/features/courses/models/ocw_course.dart`
- `dart/app/lib/features/courses/models/ocw_lecture.dart`
- `dart/app/lib/features/courses/models/ocw_resource.dart`
- `dart/app/lib/features/courses/providers/ocw_course_provider.dart`
- `dart/app/lib/features/courses/providers/ocw_lecture_provider.dart`
- `dart/app/lib/features/courses/providers/ocw_resources_provider.dart`
- `dart/app/lib/features/sync/fetchers/ocw_course_fetcher.dart`
- `dart/app/lib/features/courses/utils/ocw_html_parser.dart` — HTML → model parsing.
- `dart/app/lib/features/courses/utils/ocw_resource_matcher.dart` — name/number matching.
- `dart/app/lib/features/courses/utils/ocw_resource_html_builder.dart` — synthesized xblock HTML.
- Drift migration adding `cached_ocw_courses`, `cached_ocw_lectures`, `cached_ocw_resources` tables.
- `dart/app/test/fixtures/ocw/` — HTML samples + expected parser output.
- Tests under `dart/app/test/features/courses/` for parser + matcher + HTML builder.

### Modified

- `dart/app/lib/features/sync/providers/sync_controller.dart` — per-course-type dispatch; OCW fetcher wired in.
- `dart/app/lib/features/sync/providers/sync_reconciliation.dart` (or equivalent) — include OCW course delete-cascade targets.
- `dart/app/lib/features/courses/providers/list_contents_provider.dart` (or whatever `course-shortlist-sync` introduces for learn.mit.edu list expansion) — flip `supported = true` for OCW items.
- `dart/app/lib/features/courses/screens/course_outline_screen.dart` — append course-level "Resources" section when orphan resources exist; render OCW short description header.
- `dart/app/lib/features/courses/screens/lecture_screen.dart` — handle the `mp4Url == null` case (show "not available" inline with a browser deep-link); otherwise unchanged.
- `dart/app/lib/core/storage/app_database.dart` — register new tables, bump `schemaVersion`.
- `dart/app/lib/features/downloads/providers/video_download_manager.dart` — no logic change; verify the URL-as-PK model handles OCW CloudFront/CDN URLs identically.
- Existing adjacent specs touched: `course-shortlist-sync.md` (`supported` flag flipped for OCW), `single-page-lecture.md` (reused unchanged), `app-offline-video.md` (reused unchanged), `sane-html-parsing.md` (synthesized resource HTML flows through the existing sanitizer).

---

## Out of Scope

- OCW search / browse / URL paste inside the app.
- Resource types beyond `lecture-notes` + `lecture-slides`.
- YouTube playback (YouTube-only lectures render a "not available" state).
- Transcripts / subtitles for OCW video.
- Progress tracking (watch position, completion, server sync).
- In-app PDF viewing — all resource taps open the system browser.
- Course-run grouping UI — each run is its own course.
- Rich OCW metadata (instructor photos, citation blocks, etc.) beyond title + course number + short description.
- Migration prompts / banners for existing shortlist-sync users.

---

## Implementation Notes

**Phase 1 (python-tools/ocw-client/) — April 2026**

Stood up the OCW discovery tool that all downstream Flutter work consumes.

**Key files added**:
- `python-tools/ocw-client/client.py` — `OcwClient` + pure parsers (`parse_course_home`, `parse_video_gallery`, `parse_lecture_page`, `parse_lecture_notes_page`) + resource-to-lecture matcher + dataclass models (`OcwCourse`, `OcwSection`, `OcwLecture`, `OcwResource`, `OcwResourceType`). Includes `build_course_from_fixtures` for offline orchestration.
- `python-tools/ocw-client/cli.py` — Click CLI with `course`, `lecture`, `resources`, `match` subcommands. All support `--json` and `--fixture-dir`.
- `python-tools/ocw-client/CLAUDE.md` — documents URL patterns, extraction rules, matching algorithm, known quirks, reference courses.
- `python-tools/ocw-client/fixtures/9-13-the-human-brain-spring-2019/` — committed HTML for course home, video gallery, lecture notes, lecture 1. Happy path fixture (clean 1:1 video↔notes matches).
- `python-tools/ocw-client/fixtures/18-06-linear-algebra-spring-2010/` — committed HTML for course home, video gallery, lecture 1. No-notes variant (35 MP4 lectures, no `/pages/lecture-notes/` page).
- `python-tools/ocw-client/tests/test_parser.py` + `test_matcher.py` — 24 tests covering lecture-number extraction (including "Recitation N" negative case, `_l{NN}` URL extraction, off-by-one collisions), fixture-based parser tests, and an end-to-end network-isolation guard.

**Dependencies**: No new packages. Uses the existing `python-tools/requirements.txt` (`requests`, `click`, `beautifulsoup4`) + `pytest` for tests.

**Deviations from plan**:
- **Discovery via direct HTTPS** (per user choice during planning), not mitmproxy captures. Skipped `captures/` additions for this phase since OCW is a public static site with no auth and the committed HTML fixtures serve the same parser-provenance purpose.
- **`<h1>` vs `<h2>` on lecture pages**: discovered during first test run that `<h1>` on an OCW lecture page is the COURSE title ("The Human Brain") and the LECTURE title is in `<h2>`. `parse_lecture_page` was updated to prefer the `<title>` tag (pipe-split first segment) with an `<h2>` fallback.

**What's next (Phase 2+)**:
- Flutter data layer (Drift tables, Dart models, HTML parser port).
- `SyncController` per-course-type dispatch + `OcwCourseFetcher`.
- Flutter UI (course outline Resources section + description header, `LectureScreen` `mp4Url == null` handling).
- Flipping the `supported` flag on OCW items inside learn.mit.edu list contents — **blocked on** `course-shortlist-sync`'s learn.mit.edu list-fetch / reconciliation being implemented in code (tables landed; wiring not yet).

**Verification**:
```
cd python-tools/ocw-client
python -m pytest tests/ -q                                    # 24 passed
python cli.py course 9-13-the-human-brain-spring-2019 --fixture-dir fixtures/9-13-the-human-brain-spring-2019
python cli.py lecture 9-13-the-human-brain-spring-2019 lecture-2-neuroanatomy    # live HTTP → archive.org MP4
```
