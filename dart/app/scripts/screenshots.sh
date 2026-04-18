#!/usr/bin/env bash
# Runs the integration_test screenshot capture against a booted simulator
# or connected device. Credentials come from .screenshots.env (gitignored).
#
# Usage:
#   scripts/screenshots.sh                  # uses first available device
#   scripts/screenshots.sh <device-id>      # explicit flutter device id
#
# Prereqs:
#   - fvm + Flutter SDK resolved
#   - An iOS simulator booted (xcrun simctl boot "iPhone 16 Pro Max")
#     or an Android emulator running
#   - dart/app/.screenshots.env with SCREENSHOT_EMAIL + SCREENSHOT_PASSWORD
#
# PNGs land in dart/app/screenshots/raw/.

set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".screenshots.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy .screenshots.env.example and fill in creds." >&2
  exit 1
fi

# Parse KEY=VALUE lines literally — no $VAR expansion, no quote stripping
# beyond one pair of surrounding quotes. Credentials with $ / ` / \ / spaces
# pass through untouched.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  # Strip matching surrounding single or double quotes.
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  export "$key=$value"
done < "$ENV_FILE"

: "${SCREENSHOT_EMAIL:?SCREENSHOT_EMAIL not set in $ENV_FILE}"
: "${SCREENSHOT_PASSWORD:?SCREENSHOT_PASSWORD not set in $ENV_FILE}"

DEVICE_ARG=()
if [[ $# -ge 1 ]]; then
  DEVICE_ARG=(-d "$1")
fi

mkdir -p screenshots/raw

fvm flutter drive \
  "${DEVICE_ARG[@]}" \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshots_test.dart \
  --flavor=dev \
  -t lib/main_dev.dart \
  --dart-define=SCREENSHOT_MODE=true \
  --dart-define="SCREENSHOT_EMAIL=$SCREENSHOT_EMAIL" \
  --dart-define="SCREENSHOT_PASSWORD=$SCREENSHOT_PASSWORD"

echo ""
echo "Done. PNGs in: $(pwd)/screenshots/raw/"
ls -1 screenshots/raw/ 2>/dev/null || true
