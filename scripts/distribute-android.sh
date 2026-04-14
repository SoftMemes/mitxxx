#!/usr/bin/env bash
set -euo pipefail

RELEASE_NOTES="${1:-}"
ANDROID_APP_ID="${FIREBASE_ANDROID_APP_ID:-1:478154015759:android:927c5c829f9197bed54f7a}"
TESTER_GROUP="${FIREBASE_TESTER_GROUP:-internal}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/dart/app"

echo "==> Building Android release APK..."
cd "$APP_DIR"
flutter build apk --release

APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"

echo "==> Uploading to Firebase App Distribution..."
firebase appdistribution:distribute "$APK" \
  --app "$ANDROID_APP_ID" \
  --groups "$TESTER_GROUP" \
  ${RELEASE_NOTES:+--release-notes "$RELEASE_NOTES"}

echo "==> Done. Testers will receive an email with the APK link."
