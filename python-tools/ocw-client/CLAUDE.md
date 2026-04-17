# ocw-client

Unofficial Python client for MIT OpenCourseWare (`ocw.mit.edu`).

**Unofficial** — not affiliated with MIT or MIT OpenCourseWare. Uses
reverse-engineered HTML scraping (no auth, no documented API).

## Purpose

Discovery + extraction tooling for OCW course content, so the Flutter app can
sync OCW courses alongside MITx courses. Implements Phase 1 of
`specs/opencourseware-support.md` — the Flutter data layer and sync integration
build on top of this tool.

## Architecture

- `client.py` — `OcwClient` (HTTP) + module-level parsers + resource-to-lecture
  matcher + dataclass models (`OcwCourse`, `OcwSection`, `OcwLecture`,
  `OcwResource`, `OcwResourceType`). Parsers accept HTML strings and are pure,
  so tests run against committed fixtures with no network.
- `cli.py` — Click CLI wrapping the client. All commands support `--json` and
  `--fixture-dir <path>` for offline runs.
- `fixtures/` — committed HTML + `expected.json` for reference courses. Drives
  the parser tests and lets `cli.py` run offline-only.

## Platform overview

- Host: `ocw.mit.edu` (public static site; no auth, no cookies).
- Videos: hosted on `archive.org` (not CloudFront). Exposed via a plain
  `<a href>` on each lecture page whose visible text is "Download video". The
  href points at an MP4 (e.g. `https://archive.org/download/MIT9.13S19/MIT9_13S19_lec01_300k.mp4`).
  OCW also embeds a YouTube iframe on the same page — we ignore it entirely.
- Lecture notes / slides: static PDF/HTML resources under
  `/courses/{slug}/resources/...`, typically enumerated on a
  `/pages/lecture-notes/` page (when the course has one).

## URL patterns

| Path | Purpose |
|---|---|
| `/courses/{slug}/` | Course home |
| `/courses/{slug}/video_galleries/{gallery-slug}/` | Flat list of lecture links |
| `/courses/{slug}/resources/{lecture-slug}/` | Individual lecture page (video download link) |
| `/courses/{slug}/pages/lecture-notes/` | Lecture-notes hub (when present) |
| `/courses/{slug}/pages/readings/` | Readings (out of scope — often external DOI links) |
| `/courses/{slug}/download` | Bulk ZIP (noted; not used) |

Gallery slug varies per course: `lecture-videos` (9.13) or `video-lectures` (18.06).

## Extraction rules

### Course home — `parse_course_home(html, slug)`

- Title: first non-OCW-boilerplate `<h1>` inside `body.course-home-page`.
- Description: `<meta name="description">` / `<meta property="og:description">`.
- Course number + term: parsed from a header span like
  `"9.13 | Spring 2019 | Undergraduate"`. Falls back to deriving the course
  number from the URL slug (`9-13-...` → `9.13`, `8-01sc-...` → `8.01sc`).
- Video gallery + lecture notes paths: discovered by walking sidebar `<a>` tags
  for `/courses/{slug}/video_galleries/` (first hit wins) and `/courses/{slug}/pages/lecture-notes` (link text must equal "Lecture Notes").

### Video gallery — `parse_video_gallery(html, slug)`

- Return an ordered list of `{"slug": ..., "title": ...}` for each `<a>` whose
  `href` starts with `/courses/{slug}/resources/` and whose path segment begins
  with `lecture-`.
- Galleries observed so far are flat (no unit/week groupings). If a course
  introduces groupings via `<h2>`/`<h3>` between lecture blocks, extend here;
  today we always return a single synthetic "Video Lectures" section.

### Lecture page — `parse_lecture_page(html)`

- Title: first `<h1>`; strip the trailing `| ... | MIT OpenCourseWare` suffix.
- MP4: first `<a>` whose visible text (lowercased + whitespace-collapsed)
  contains `"download video"` AND whose `href` contains `archive.org` or ends
  in `.mp4`. If neither condition matches, `mp4_url = None` (e.g. in-class
  dissection sessions; YouTube-only lectures).
- Duration: not surfaced on OCW pages; always `None`.

### Lecture-notes page — `parse_lecture_notes_page(html, slug, base_url)`

- Every `<a>` whose visible text contains `"(PDF"` and whose `href` points
  under the same course's `/resources/` path is treated as a downloadable
  resource. Title strips the trailing `(PDF - X.YMB)` suffix OCW appends.
- Current type inference: everything on this page is typed as
  `lecture-notes`. No separate "lecture slides" page has been observed in the
  reference set; when a course ships both, split by sidebar section heading.

## Resource → lecture matching — `match_resources_to_lectures`

Algorithm (first match wins):

1. Extract lecture number from both sides via `extract_lecture_number` (regex):
   - `\blec(?:ture)?\s*(\d+)` → e.g. "Lecture 14", "Lec 14".
   - `_l(\d+)\b` → e.g. `mit9_13s19_l14`.
   - `\b(\d+)\.pdf$` → e.g. `lec14.pdf`.
   - `^(\d+)[_\-.]` → e.g. `01_handout.pdf`.
2. If both sides yield the same number → assign.
3. Else, normalized-title prefix match (lowercase, punctuation stripped,
   whitespace collapsed): `startswith` in either direction.
4. Else → orphan (surfaced at course level).

"Recitation 14" is **not** matched to "Lecture 14" — the regex is anchored to
the `lecture`/`lec` prefix.

## Known quirks

- **18.06 Linear Algebra (Spring 2010)** has no `/pages/lecture-notes/` page.
  Readings page points at textbook chapters (external references). Resource
  list is empty; zero orphans; all 35 lectures have archive.org MP4 links.
- **9.13 The Human Brain (Spring 2019)** has clean per-lecture notes named
  `mit9_13s19_l{NN}`. 17 lectures have both video and notes; the in-class
  dissection lectures (3, 12, 14, 17, 19, 22, 23, 25) are missing from the
  gallery entirely.
- Older MP4 URLs use `http://` not `https://` (e.g. 18.06). The Flutter app
  should normalise to https at ingestion time or leave unchanged; archive.org
  serves both.
- Some lectures have no video even when they appear in the gallery. `mp4_url`
  is `None` in that case — surface with a "video not available" state.
- YouTube-only lectures are out of scope for this tool; `mp4_url` will be
  `None`.

## Reference courses

Committed in `fixtures/`:

- `9-13-the-human-brain-spring-2019` — happy path. Clean 1:1 video↔notes.
- `18-06-linear-algebra-spring-2010` — no-notes variant. 35 MP4 lectures.

Additional reference courses for future fixtures: `6-006-...` (for unit/week
grouping), `8-01-...` (for legacy page structures).

## Usage

```bash
cd python-tools
python -m pip install -r requirements.txt   # shared deps (requests, click, beautifulsoup4)
cd ocw-client

# Live (fetches ocw.mit.edu)
python cli.py course 9-13-the-human-brain-spring-2019
python cli.py lecture 9-13-the-human-brain-spring-2019 lecture-1-introduction
python cli.py resources 9-13-the-human-brain-spring-2019
python cli.py match 9-13-the-human-brain-spring-2019

# Offline (reads committed fixtures)
python cli.py course 9-13-the-human-brain-spring-2019 \
  --fixture-dir fixtures/9-13-the-human-brain-spring-2019

# Tests
python -m pytest tests/ -q
```

`--json` is available on `course`, `lecture`, and `resources` for
machine-readable output.

## What this tool does NOT do

- No auth / session management (unlike `mitx-client`).
- No video download (the Flutter app's `VideoDownloadManager` owns that; CLI
  just surfaces the MP4 URL).
- No transcript, problem-set, readings, code, or notebook extraction (out of
  scope for v1 per `specs/opencourseware-support.md`).
- No in-app search / course browse — discovery happens via learn.mit.edu lists.
- No YouTube fallback for lectures that lack a direct MP4.
