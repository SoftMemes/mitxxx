# mitx-client

Core Python API client and CLI for interacting with the MITx / MIT OpenLearning platform.

**Unofficial** — uses reverse-engineered endpoints from mitmproxy captures.

## Architecture

- `client.py` — `MITxClient` class: handles auth, session management, all API calls
- `cli.py` — Click-based CLI wrapping the client for interactive use

## Auth

Full 4-stage OAuth2 flow:
1. `mitxonline.mit.edu/login/` → Keycloak SSO redirect
2. POST credentials to Keycloak → redirect back to mitxonline with session
3. LMS OAuth2 handshake → JWT cookies on courses.learn.mit.edu
4. MIT Learn API SSO handshake (`api.learn.mit.edu/login`) → `session_mitlearn` + `learn_csrftoken` cookies

Sessions are persisted to `~/.mitx-client/session.json` so you only need to log in once.

The MIT Learn API session can become silently stale — `session_mitlearn` stays
present in the cookie jar but the API returns empty results instead of 401. The
client always re-runs stage 4 once per `MITxClient` instance (on first MIT Learn
API call) to avoid this.

## Usage

```bash
# Login (saves session)
python cli.py login

# Show current user
python cli.py whoami

# List enrolled courses
python cli.py enrollments

# Show course outline (sections/sequences)
python cli.py outline course-v1:MITxT+24.09x+1T2025

# Show sequence items
python cli.py sequence block-v1:MITxT+24.09x+1T2025+type@sequential+block@...

# Get xblock content (HTML) and extract video URLs
python cli.py xblock block-v1:MITxT+24.09x+1T2025+type@vertical+block@...

# Download a video from a vertical block
python cli.py download-video block-v1:MITxT+24.09x+1T2025+type@vertical+block@... --output ./videos/

# Get transcript for a video block
python cli.py transcript block-v1:...type@video+block@... --lang en

# List the user's custom "My Lists" from learn.mit.edu
python cli.py list-playlists

# Dump courses in a playlist (annotated [supported]/[ocw]/[other])
python cli.py dump-playlist 458739
```

## MIT Learn API (api.learn.mit.edu)

Used for user-created lists ("My Lists" on `learn.mit.edu/dashboard/my-lists`).
Separate subdomain from `learn.mit.edu` (the SPA host) — the API lives on
`api.learn.mit.edu` and takes its own session cookies.

| Endpoint | Purpose |
|---|---|
| `GET /login` | SSO handshake (stage 4); sets `session_mitlearn` + `learn_csrftoken` |
| `GET /api/v0/users/me/` | Auth check for api.learn.mit.edu session |
| `GET /api/v1/userlists/?limit=100` | The authenticated user's custom lists (paginated) |
| `GET /api/v1/userlists/{id}/items/?limit=1000` | Items inside a single list (paginated) |
| `GET /api/v1/userlists/membership/` | Flat memberships table (list_id → learning_resource_id) |
| `GET /mitxonline/api/v3/enrollments/` | Proxied mitxonline v3 enrollments (same shape as mitxonline.mit.edu/api/v1/enrollments/) |

### Userlist object shape

```json
{
  "id": 458739,
  "topics": [],
  "item_count": 2,
  "image": { "url": "...", "alt": "..." } | null,
  "title": "Favorites",
  "description": "My Favorites",
  "privacy_level": "private",
  "author": 953872
}
```

List IDs are integers. The same integer appears in the user-facing URL
`learn.mit.edu/dashboard/my-lists/{id}`.

### Userlist item object shape

`GET /api/v1/userlists/{id}/items/` returns paginated results where each item is:

```json
{
  "id": 162434,                // membership id
  "parent": 458739,            // list id
  "child": 13920,              // learning_resource id
  "position": 0,
  "resource": {
    "id": 13920,
    "readable_id": "course-v1:MITxT+24.09x",
    "title": "...",
    "resource_type": "course",
    "platform": { "code": "mitxonline", "name": "MITx Online" },
    "runs": [ { "courseware_id": "course-v1:MITxT+24.09x+1T2025", "run_tag": "1T2025", ... } ],
    "best_run_id": 12345,
    ...
  }
}
```

### Detecting "supported" courses (for this app)

The app can sync only courses that run on `courses.learn.mit.edu` — i.e. mitxonline platform.
The canonical filter is:

```
supported = (resource.platform.code == "mitxonline")
```

Other platform codes observed: `ocw` (MIT OpenCourseWare — static web courses),
`edx` (edx.org — not our LMS). Both are excluded from sync.

### Mapping to Open edX courseware_id

For supported items the Open edX identifier used by courses.learn.mit.edu is in
`resource.runs[*].courseware_id`. For OCW/edx items these fields are `None`.

When reconciling against the user's enrollments, match the resource by its
`courseware_id` to the enrollment's `run.courseware_id`.
