#!/usr/bin/env bash
# One-command refresh of store marketing screenshots:
#   1. Captures raw Patrol screenshots on the booted device (via
#      scripts/integration.sh screenshots ...).
#   2. Runs the Python compositor to package them into store-ready
#      marketing PNGs under screenshots/packaged/.
#   3. Syncs the packaged PNGs into fastlane/metadata/ so
#      `fastlane upload_screenshots` can pick them up.
#
# Pass-through args go to integration.sh (device id, platform override).
#
# Usage:
#   scripts/screenshots.sh                     # default device
#   scripts/screenshots.sh emulator-5556       # android serial
#   PLATFORM=ios scripts/screenshots.sh <udid> # iOS simulator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"
VENV_PY="$REPO_ROOT/python-tools/.venv/bin/python"

cd "$APP_DIR"
"$SCRIPT_DIR/integration.sh" screenshots "$@"

if [[ ! -x "$VENV_PY" ]]; then
  echo "[screenshots.sh] $VENV_PY not found." >&2
  echo "Set up the shared python-tools venv first:" >&2
  echo "  python3 -m venv python-tools/.venv" >&2
  echo "  python-tools/.venv/bin/pip install -r python-tools/requirements.txt" >&2
  exit 1
fi

"$VENV_PY" "$REPO_ROOT/python-tools/screenshot-composer/cli.py" --sync-fastlane
