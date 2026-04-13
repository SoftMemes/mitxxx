#!/usr/bin/env bash
# Stop hook: run `flutter analyze` in dart/app and block if there are issues.
# Fires whenever Claude finishes a response. The stop_hook_active flag prevents
# infinite loops — if the hook itself triggered this stop, skip re-running.

set -euo pipefail

INPUT=$(cat)

# Avoid infinite loop: if Claude is already responding to a hook failure, let it stop.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# Only run when the dart app directory exists relative to the repo root.
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$REPO_ROOT/dart/app"

if [ ! -f "$APP_DIR/pubspec.yaml" ]; then
  exit 0
fi

# Run analysis. Capture combined output; suppress the progress spinner line.
ANALYZE_OUTPUT=$(cd "$APP_DIR" && /home/freed/fvm/bin/fvm flutter analyze 2>&1 | grep -v '^$') || true

# If the output contains "No issues found", analysis is clean — allow stop.
if echo "$ANALYZE_OUTPUT" | grep -q "No issues found"; then
  exit 0
fi

# If there are issues (errors or warnings), block and surface them.
if echo "$ANALYZE_OUTPUT" | grep -qE "^\s*(error|warning|info)\s"; then
  echo "flutter analyze found issues — fix them before finishing:" >&2
  echo "" >&2
  echo "$ANALYZE_OUTPUT" >&2
  exit 2
fi

# Fallback: something unexpected; allow stop.
exit 0
