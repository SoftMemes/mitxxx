# mitx-client

Core Python API client and CLI for interacting with the MITx / MIT OpenLearning platform.

**Unofficial** — uses reverse-engineered endpoints from mitmproxy captures.

## Architecture

- `client.py` — `MITxClient` class: handles auth, session management, all API calls
- `cli.py` — Click-based CLI wrapping the client for interactive use

## Auth

Full 3-stage OAuth2 flow:
1. `mitxonline.mit.edu/login/` → Keycloak SSO redirect
2. POST credentials to Keycloak → redirect back to mitxonline with session
3. LMS OAuth2 handshake → JWT cookies on courses.learn.mit.edu

Sessions are persisted to `~/.mitx-client/session.json` so you only need to log in once.

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
```

## Session Storage

Sessions saved to `~/.mitx-client/session.json` (cookies for both hosts).
Delete this file to force re-login.
