#!/usr/bin/env bash
# Distribute to both Android and iOS testers via Firebase App Distribution.
# Usage: ./scripts/distribute.sh "release notes"
set -euo pipefail

RELEASE_NOTES="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/distribute-android.sh" "$RELEASE_NOTES"
"$SCRIPT_DIR/distribute-ios.sh" "$RELEASE_NOTES"
