# MITx API Discovery Notes

Discovered by analyzing `captures/mitx-login-discover-courses-download-video.flow` with `analyze.py`.

---

## Overview

The MITx platform consists of two main services that talk to each other:

| Service | Host | What it does |
|---|---|---|
| **MITx Online Portal** | `mitxonline.mit.edu` | Your account, enrollments, checkout, profile |
| **Open edX LMS** | `courses.learn.mit.edu` | Actual course content, videos, problems, discussions |
| **Keycloak SSO** | `sso.ol.mit.edu` | Single sign-on identity provider |
| **Video CDN** | `d3tsb3m56iwvoq.cloudfront.net` | Video file delivery (AWS CloudFront) |

---

## How Login Works

Login is a 3-hop process, but once you have it working it's invisible to the user:

```
Your app
  │
  ├─ 1. GET mitxonline.mit.edu/login/
  │       ↓ redirects to...
  │
  ├─ 2. GET sso.ol.mit.edu/realms/olapps/protocol/openid-connect/auth
  │       This is the Keycloak login page. User enters email + password.
  │       POST /realms/olapps/login-actions/authenticate
  │       ↓ on success, redirects back to mitxonline with a code
  │
  ├─ 3. GET mitxonline.mit.edu/login/.apisix/redirect?code=...
  │       mitxonline exchanges the code and sets a session cookie.
  │       → You now have: session cookie on mitxonline.mit.edu
  │
  └─ 4. GET courses.learn.mit.edu/auth/login/ol-oauth2/
          This triggers an OAuth2 flow between the LMS and mitxonline.
          mitxonline.mit.edu/oauth2/authorize/ → back to LMS
          → You now have: JWT cookies + session on courses.learn.mit.edu
```

**Result — cookies you need to keep:**
- `session` on `mitxonline.mit.edu`
- `mitxonline-production-edx-lms-sessionid` on `courses.learn.mit.edu`
- `mitxonline-production-edx-jwt-cookie-header-payload` (JWT, split into 2 cookies)
- `mitxonline-production-edx-jwt-cookie-signature`
- `csrftoken` on `courses.learn.mit.edu` — needed for any POST request

The JWT cookies expire; the LMS OAuth step can be re-triggered without re-entering credentials as long as the mitxonline session is alive.

---

## What You Can Do Once Logged In

### 1. Find out who you are

```
GET mitxonline.mit.edu/api/v0/users/current_user/
```
Returns your username, email, profile info, and `is_authenticated: true/false`. Good health check.

---

### 2. List your enrolled courses

```
GET mitxonline.mit.edu/api/v1/enrollments/
```
Returns an array. Each item has:
- `run.title` — "Minds and Machines"
- `run.courseware_id` — e.g. `"course-v1:MITxT+24.09x+1T2025"` — the ID you need for everything else
- `run.courseware_url` — direct URL to the course home page
- `enrollment_mode` — `"audit"` or `"verified"`
- `run.start_date`, `run.end_date`

---

### 3. Get a course's structure

**Step 3a — Course outline (sections and sequences):**
```
GET courses.learn.mit.edu/api/learning_sequences/v1/course_outline/{course_id}
```
Returns the full tree:
```
course
  └── sections (weeks/parts)  — type "chapter"
        └── sequences (lectures)  — type "sequential"
```
Each section has a list of `sequence_ids`. This is the navigation structure you see in the sidebar.

**Step 3b — What's inside a sequence:**
```
GET courses.learn.mit.edu/api/courseware/sequence/{sequence_block_id}
```
Returns a list of `items` (verticals — individual pages). Each item has:
- `id` — the vertical block ID
- `type` — `"video"`, `"problem"`, or `"other"`
- `page_title` — human-readable name
- `complete` — whether the user has completed it

---

### 4. Get the actual content of a page

```
GET courses.learn.mit.edu/xblock/{vertical_block_id}
```
Returns HTML. This is the raw content of a single page in the course. It contains the actual lesson content.

For video pages, the HTML contains a special `data-metadata` JSON attribute on a div element. This JSON has:
- `sources` — array of video URLs (MP4 and HLS)
- `duration` — video length in seconds
- `transcriptTranslationUrl` — URL template for fetching transcripts
- `transcriptLanguages` — available transcript languages (e.g. `{"en": "English"}`)

---

### 5. Download a video

Videos are on AWS CloudFront. The URLs look like:
```
https://d3tsb3m56iwvoq.cloudfront.net/transcoded/{hash}/video_custom.mp4
https://d3tsb3m56iwvoq.cloudfront.net/transcoded/{hash}/video__index.m3u8
```

**Crucially — these are unsigned, no auth required.** Once you have the URL from the xblock HTML, you can download it with a plain HTTP GET.

Both MP4 (direct download, good for offline) and HLS (adaptive streaming, good for streaming) are available.

---

### 6. Get a transcript

```
GET courses.learn.mit.edu/courses/{course_id}/xblock/{video_block_id}/handler/transcript/translation/en
```
Returns an SRT subtitle file. The `video_block_id` is `block-v1:...+type@video+block@...` (different from the vertical block ID — found in the `publishCompletionUrl` inside the xblock metadata JSON).

There's also a download endpoint:
```
GET courses.learn.mit.edu/courses/{course_id}/xblock/{video_block_id}/handler/transcript/download
```

---

## Block ID Format

Open edX uses structured IDs throughout:

| Format | Example | Meaning |
|---|---|---|
| `course-v1:ORG+NUMBER+RUN` | `course-v1:MITxT+24.09x+1T2025` | A course run |
| `block-v1:ORG+NUMBER+RUN+type@TYPE+block@HASH` | `block-v1:MITxT+...+type@sequential+block@e79ab164...` | A content block |

Block types seen:
- `course` — top-level course
- `chapter` — section/week
- `sequential` — sequence/lecture (a unit of navigation)
- `vertical` — a single page in the course
- `video` — a video block inside a vertical
- `problem` — a question/quiz block
- `html` — a text/HTML block

---

## Other Useful Endpoints Found

| Endpoint | Purpose |
|---|---|
| `GET /csrf/api/v1/token` | Get CSRF token for POST requests |
| `GET /api/course_home/course_metadata/{course_id}` | Course access check (`has_access`), enrollment status |
| `GET /api/courseware/course/{course_id}` | Course details including image, description, pacing |
| `GET /api/discussion/v1/courses/{course_id}` | Discussion forum info and thread list URLs |
| `POST /courses/{course_id}/xblock/{seq_id}/handler/goto_position` | Mark position in sequence (for progress tracking) |
| `POST /courses/{course_id}/xblock/{block_id}/handler/publish_completion` | Mark a block as complete |
| `GET /api/v1/program_enrollments/` | List program enrollments (usually empty for individual courses) |
| `GET /api/courses/v1/blocks/` | Alternative way to fetch course blocks tree |

---

## What Needs Auth vs. What Doesn't

| Resource | Auth Required? |
|---|---|
| Login page | No |
| User profile, enrollments | Yes (mitxonline session) |
| Course structure, xblocks | Yes (LMS session) |
| Video files on CloudFront | **No** — URLs are unsigned |
| Transcripts | Yes (LMS session) |

This means: once you've parsed the video URLs out of the xblock HTML, you can download them freely without any authentication headers.
