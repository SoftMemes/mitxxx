#!/usr/bin/env bash
set -euo pipefail

RELEASE_NOTES="${1:-}"
IOS_APP_ID="${FIREBASE_IOS_APP_ID:-1:478154015759:ios:1d84be350debcdd2d54f7a}"
TESTER_GROUP="${FIREBASE_TESTER_GROUP:-internal}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/dart/app"

echo "==> Building iOS release IPA..."
cd "$APP_DIR"
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist

IPA="$APP_DIR/build/ios/ipa/emajtee.ipa"

echo "==> Uploading to Firebase App Distribution..."
firebase appdistribution:distribute "$IPA" \
  --app "$IOS_APP_ID" \
  --groups "$TESTER_GROUP" \
  ${RELEASE_NOTES:+--release-notes "$RELEASE_NOTES"}

echo "==> Done. Registered testers will receive an install link."
