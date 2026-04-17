# MITxxx — Unofficial MITx Offline Course App

**This is an unofficial app for MITx / MIT OpenLearning courses and is clearly marked as such.**
The goal is offline access to enrolled courses on iOS and Android. If it gains traction, the intent is to work with MIT to make it official.

## Project Structure

```
captures/           mitmproxy flow captures for protocol analysis
python-tools/       Python discovery tools, API clients, utilities
  requirements.txt  shared Python dependencies
  flow-analyzer/    parse + dump mitmproxy flow files
  mitx-client/      core API client + CLI for MITx
```

## Platform Overview

MITx uses two main hosts:
- `mitxonline.mit.edu` — portal, user management, enrollment management
- `courses.learn.mit.edu` — Open edX LMS with course content, xblocks, video

## Auth Flow (3-stage OAuth2)

1. `mitxonline.mit.edu/login/` → redirects to Keycloak SSO at `sso.ol.mit.edu`
2. POST credentials to Keycloak → redirect back to `mitxonline.mit.edu` with session cookie
3. LMS OAuth2: `courses.learn.mit.edu/auth/login/ol-oauth2/` → `mitxonline.mit.edu/oauth2/authorize/` → LMS sets JWT cookies + session

**Session cookies to maintain:**
- `session` on `mitxonline.mit.edu`
- `mitxonline-production-edx-lms-sessionid` on `courses.learn.mit.edu`
- `mitxonline-production-edx-jwt-cookie-header-payload` + `...-signature`
- `csrftoken` for POST requests (get from `/csrf/api/v1/token`)

## Key API Endpoints

### mitxonline.mit.edu
| Endpoint | Purpose |
|---|---|
| `GET /api/v0/users/current_user/` | user profile, auth check |
| `GET /api/v1/enrollments/` | list enrolled course runs |
| `GET /api/v1/program_enrollments/` | list program enrollments |

### courses.learn.mit.edu (LMS / Open edX)
| Endpoint | Purpose |
|---|---|
| `GET /api/course_home/course_metadata/{course_id}` | course metadata, access check |
| `GET /api/course_home/outline/{course_id}` | course outline with block tree |
| `GET /api/learning_sequences/v1/course_outline/{course_id}` | sections + sequences |
| `GET /api/courseware/course/{course_id}` | full course info |
| `GET /api/courseware/sequence/{block_id}` | sequence items (verticals), types |
| `GET /xblock/{block_id}` | vertical HTML with embedded video metadata |
| `GET /csrf/api/v1/token` | CSRF token for POST requests |

## Course/Block ID Format

Open edX uses a `course-v1:ORG+NUMBER+RUN` format for course IDs, e.g.:
- `course-v1:MITxT+24.09x+1T2025`

Block IDs use `block-v1:ORG+NUMBER+RUN+type@TYPE+block@HASH`, e.g.:
- `block-v1:MITxT+24.09x+1T2025+type@sequential+block@e79ab164...`
- `block-v1:MITxT+24.09x+1T2025+type@vertical+block@d5a0ff74...`
- `block-v1:MITxT+24.09x+1T2025+type@video+block@36e673ee...`

## Video Delivery

Videos are served from CloudFront CDN: `d3tsb3m56iwvoq.cloudfront.net`
- MP4: `transcoded/{hash}/video_custom.mp4`
- HLS: `transcoded/{hash}/video__index.m3u8`
- **No auth required** — URLs are unsigned
- URLs are embedded in xblock HTML responses as JSON in `data-metadata` attribute, under `sources` array

Transcripts available via LMS handler:
`/courses/{course_id}/xblock/{video_block_id}/handler/transcript/translation/{lang}`

## python-tools Conventions

- Every tool lives in its own subdirectory under `python-tools/`
- Every tool directory has a `CLAUDE.md` explaining what it does and why
- Keep tools around even if single-use/throwaway — they document the discovery process
- Tools share `python-tools/requirements.txt`

## Flutter / Dart commands

Always use `fvm` to run Flutter and Dart commands — this repo pins the Flutter
version via fvm. There is no global `flutter` on PATH; bare `flutter` invocations
will fail.

- `fvm flutter analyze` (not `flutter analyze`)
- `fvm flutter test`
- `fvm flutter run`
- `fvm flutter pub get`
- `fvm dart ...` for any `dart` subcommand
