#!/usr/bin/env bash
# Distribute to both Android and iOS testers via Firebase App Distribution.
# Usage: ./scripts/distribute.sh "release notes"
#   Override build number: BUILD_NUMBER=12345 ./scripts/distribute.sh "notes"
set -euo pipefail

RELEASE_NOTES="${1:-}"

# Build number: seconds since 2020-01-01 UTC.
# Offsetting from 2020 keeps the value ~200M today vs ~1.78B for raw Unix time,
# leaving ~60 years before hitting Android's signed int32 versionCode ceiling.
# The while loop halves precision if we ever get close (won't happen until ~2086).
EPOCH_2020=1577836800
ANDROID_MAX=2100000000
RAW=$(( $(date +%s) - EPOCH_2020 ))
while (( RAW > ANDROID_MAX )); do
  RAW=$(( RAW / 10 ))
done
export BUILD_NUMBER="${BUILD_NUMBER:-$RAW}"

echo "==> Build number: $BUILD_NUMBER"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/distribute-android.sh" "$RELEASE_NOTES"
"$SCRIPT_DIR/distribute-ios.sh" "$RELEASE_NOTES"
