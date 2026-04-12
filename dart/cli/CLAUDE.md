# mitx-client (Dart CLI)

Dart CLI tool for troubleshooting MITx API access. Uses the same Dio-based
HTTP stack as the Flutter app so you can reproduce auth/network issues from
the terminal without building the full app.

**Unofficial** — uses reverse-engineered endpoints from mitmproxy captures.

## Architecture

- `bin/mitx_client.dart` — entry point, `CommandRunner` with 7 subcommands
- `lib/src/client_factory.dart` — builds `MitxApiClient` with file-backed cookie persistence
- `lib/src/commands/*.dart` — one file per command
- `lib/src/video_parser.dart` — extracts video metadata from xblock HTML
- Depends on the shared `dart/packages/mitx_api` package for all HTTP/auth logic

## Session Storage

Cookies persist to `~/.mitx-dart-client/.cookies/` (via `PersistCookieJar` +
`FileStorage`). Delete that directory or run `logout` to force re-login.

## Usage

```bash
cd dart/cli
dart pub get

# Login (saves session to ~/.mitx-dart-client/.cookies/)
dart run bin/mitx_client.dart login --email you@example.com

# Show current user
dart run bin/mitx_client.dart whoami

# List enrolled courses
dart run bin/mitx_client.dart enrollments
dart run bin/mitx_client.dart enrollments --json

# Course outline (sections + sequence IDs)
dart run bin/mitx_client.dart outline course-v1:MITxT+24.09x+1T2025
dart run bin/mitx_client.dart outline course-v1:MITxT+24.09x+1T2025 --json

# Sequence items (verticals)
dart run bin/mitx_client.dart sequence block-v1:MITxT+...+type@sequential+block@...

# xblock content (video metadata)
dart run bin/mitx_client.dart xblock block-v1:MITxT+...+type@vertical+block@...
dart run bin/mitx_client.dart xblock block-v1:... --show-html   # raw HTML
dart run bin/mitx_client.dart xblock block-v1:... --json        # video metadata JSON

# Logout (deletes saved cookies)
dart run bin/mitx_client.dart logout
```

## Verbose Logging

Set `MITX_VERBOSE=1` to see all HTTP requests, redirect hops, and auth steps:

```bash
MITX_VERBOSE=1 dart run bin/mitx_client.dart login
```

## Relationship to Python Client

This is a functional port of `python-tools/mitx-client/` using the same Dio
library as the Flutter app. Use it when you suspect the issue is in the
app's HTTP layer rather than the UI — if this CLI works, the problem is in
the Flutter-specific code (WebView cookie sync, Riverpod state, etc.).
