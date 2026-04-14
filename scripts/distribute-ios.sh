#!/usr/bin/env bash
set -euo pipefail

RELEASE_NOTES="${1:-}"
IOS_APP_ID="${FIREBASE_IOS_APP_ID:-1:478154015759:ios:1d84be350debcdd2d54f7a}"
TESTER_GROUP="${FIREBASE_TESTER_GROUP:-internal}"

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

echo "==> Cleaning stale iOS archive/IPA to ensure build number is baked in fresh..."
rm -rf "$APP_DIR/build/ios/archive" "$APP_DIR/build/ios/ipa"

echo "==> Building iOS release IPA..."
cd "$APP_DIR"
flutter build ipa --release \
  --build-number="$BUILD_NUMBER" \
  --export-options-plist=ios/ExportOptions.plist

IPA="$APP_DIR/build/ios/ipa/emajtee.ipa"

echo "==> Verifying build number in IPA..."
TMP_PLIST=$(mktemp)
unzip -p "$IPA" Payload/Runner.app/Info.plist > "$TMP_PLIST"
plutil -p "$TMP_PLIST" | grep -E 'CFBundleVersion|CFBundleShortVersionString'
rm -f "$TMP_PLIST"

echo "==> Uploading to Firebase App Distribution..."
firebase appdistribution:distribute "$IPA" \
  --app "$IOS_APP_ID" \
  --groups "$TESTER_GROUP" \
  ${RELEASE_NOTES:+--release-notes "$RELEASE_NOTES"}

echo "==> Done. Registered testers will receive an install link."
