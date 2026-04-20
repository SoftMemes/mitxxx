#!/usr/bin/env bash
# Runs a patrol integration test on a booted Android emulator or connected
# device. Credentials + test inputs come from .integration.env (gitignored).
#
# Usage:
#   scripts/integration.sh                  # default: flows mode
#   scripts/integration.sh flows            # blank-slate critical flow
#   scripts/integration.sh screenshots      # store PNG capture
#   scripts/integration.sh flows <device>   # specific device id
#
# Prereqs:
#   - fvm + Flutter SDK resolved (project pins the version).
#   - An Android emulator booted (iOS is out of scope for v1).
#   - dart/app/.integration.env populated from .integration.env.example.
#
# Outputs:
#   flows        → screenshots/failures/<label>.png on failure.
#   screenshots  → screenshots/raw/0[1-5]_*.png (five store shots).
#
# Mechanism:
#   patrol test runs on the device. The Dart test prints
#   `[patrol] SCREENSHOT <subdir> <name>` at each screenshot stop, then
#   sleeps long enough for this script to see the line and shoot the
#   screen via `adb exec-out screencap -p`.

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-flows}"
if [[ $# -ge 1 ]]; then shift; fi

case "$MODE" in
  flows)
    TARGET="integration_test/flows_test.dart"
    ;;
  screenshots)
    TARGET="integration_test/screenshots_test.dart"
    ;;
  *)
    echo "Unknown mode '$MODE'. Expected 'flows' or 'screenshots'." >&2
    exit 2
    ;;
esac

ENV_FILE=".integration.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy .integration.env.example and fill it in." >&2
  exit 1
fi

# Parse KEY=VALUE lines literally — no $VAR expansion, no quote stripping
# beyond one matching pair of surrounding quotes. Credentials with $ / `
# / \ / spaces pass through untouched.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  export "$key=$value"
done < "$ENV_FILE"

: "${INTEGRATION_EMAIL:?INTEGRATION_EMAIL not set in $ENV_FILE}"
: "${INTEGRATION_PASSWORD:?INTEGRATION_PASSWORD not set in $ENV_FILE}"
if [[ "$MODE" == "flows" ]]; then
  : "${INTEGRATION_LIST_NAMES:?INTEGRATION_LIST_NAMES not set in $ENV_FILE}"
  : "${INTEGRATION_LIST_NAMES_ALT:?INTEGRATION_LIST_NAMES_ALT not set in $ENV_FILE}"
  : "${INTEGRATION_COURSE_TITLE:?INTEGRATION_COURSE_TITLE not set in $ENV_FILE}"
  : "${INTEGRATION_LECTURE_TITLE:?INTEGRATION_LECTURE_TITLE not set in $ENV_FILE}"
fi

DEVICE_ARGS=()
if [[ $# -ge 1 ]]; then
  DEVICE_ARGS=(-d "$1")
fi

mkdir -p screenshots/raw screenshots/failures

# Awk stream filter: on every `[patrol] SCREENSHOT <subdir> <name>` line,
# run `adb exec-out screencap` and write to screenshots/<subdir>/<name>.png.
# All other lines pass through untouched so the developer still sees the
# `[patrol]` step log in real time.
SCREENCAP_AWK='
/\[patrol\] SCREENSHOT / {
  subdir = $3
  name = $4
  outfile = "screenshots/" subdir "/" name ".png"
  cmd = "adb exec-out screencap -p > " outfile
  system(cmd)
  print "[screencap] wrote " outfile
  fflush()
  next
}
{ print; fflush() }
'

# patrol test's own `--uninstall` (default on) performs the same adb
# uninstall we would run manually, so we leave it to patrol.
run_patrol() {
  set +e
  local attempt="$1"
  local log_file="$2"
  echo "[integration.sh] attempt $attempt"
  fvm dart run patrol_cli:main test \
    --target="$TARGET" \
    --flavor=dev \
    "${DEVICE_ARGS[@]}" \
    --dart-define="INTEGRATION_EMAIL=$INTEGRATION_EMAIL" \
    --dart-define="INTEGRATION_PASSWORD=$INTEGRATION_PASSWORD" \
    --dart-define="INTEGRATION_LIST_NAMES=${INTEGRATION_LIST_NAMES:-}" \
    --dart-define="INTEGRATION_LIST_NAMES_ALT=${INTEGRATION_LIST_NAMES_ALT:-}" \
    --dart-define="INTEGRATION_COURSE_TITLE=${INTEGRATION_COURSE_TITLE:-}" \
    --dart-define="INTEGRATION_LECTURE_TITLE=${INTEGRATION_LECTURE_TITLE:-}" \
    2>&1 | tee "$log_file" | awk "$SCREENCAP_AWK"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
}

# The "Total: 0 … Gradle test execution failed" mode is the known flaky
# android-reinstall path — patrol reports it but no test body ran. Retry
# once on that specific signature only; real test failures propagate as-is.
is_flaky_zero_tests() {
  local log_file="$1"
  grep -q "Total: 0" "$log_file" \
    && grep -q "Gradle test execution failed" "$log_file"
}

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

STATUS=0
run_patrol 1 "$LOG_FILE" || STATUS=$?

if [[ "$STATUS" -ne 0 ]] && is_flaky_zero_tests "$LOG_FILE"; then
  echo ""
  echo "[integration.sh] patrol reported 0 tests (flaky reinstall). retrying once…"
  sleep 2
  STATUS=0
  run_patrol 2 "$LOG_FILE" || STATUS=$?
fi

echo ""
if [[ "$MODE" == "screenshots" ]]; then
  echo "Screenshot PNGs in: $(pwd)/screenshots/raw/"
  ls -1 screenshots/raw/ 2>/dev/null || true
else
  echo "Failure PNGs (if any) in: $(pwd)/screenshots/failures/"
  ls -1 screenshots/failures/ 2>/dev/null || true
fi

exit "$STATUS"
