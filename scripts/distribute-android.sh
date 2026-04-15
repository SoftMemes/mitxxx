#!/usr/bin/env bash
set -euo pipefail

RELEASE_NOTES=""
SKIP_BUILD=false
ANDROID_APP_ID="${FIREBASE_ANDROID_APP_ID:-1:478154015759:android:927c5c829f9197bed54f7a}"
TESTER_GROUP="${FIREBASE_TESTER_GROUP:-internal}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    *) RELEASE_NOTES="$1"; shift ;;
  esac
done

# Build number: seconds since 2020-01-01 UTC (see distribute.sh for rationale).
# If BUILD_NUMBER is already set by the parent script, this is a no-op.
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  EPOCH_2020=1577836800
  ANDROID_MAX=2100000000
  RAW=$(( $(date +%s) - EPOCH_2020 ))
  while (( RAW > ANDROID_MAX )); do
    RAW=$(( RAW / 10 ))
  done
  BUILD_NUMBER="$RAW"
fi

echo "==> Build number: $BUILD_NUMBER"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/dart/app"

if [[ "$SKIP_BUILD" == true ]]; then
  echo "==> Skipping Android build (--skip-build)"
else
  echo "==> Building Android release APK..."
  cd "$APP_DIR"
  fvm flutter build apk --release --build-number="$BUILD_NUMBER"
fi

APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"

echo "==> Uploading to Firebase App Distribution..."
firebase appdistribution:distribute "$APK" \
  --app "$ANDROID_APP_ID" \
  --groups "$TESTER_GROUP" \
  ${RELEASE_NOTES:+--release-notes "$RELEASE_NOTES"}

echo "==> Done. Testers will receive an email with the APK link."
