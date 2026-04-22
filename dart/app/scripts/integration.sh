#!/usr/bin/env bash
# Runs a patrol integration test on a booted Android emulator / iOS
# simulator / connected device. Credentials + test inputs come from
# .integration.env (gitignored).
#
# Usage:
#   scripts/integration.sh                   # default: flows mode, default device
#   scripts/integration.sh flows             # blank-slate critical flow
#   scripts/integration.sh screenshots       # store PNG capture
#   scripts/integration.sh flows <device>    # specific device id (adb serial
#                                            #   or iOS sim UDID / name)
#
# Prereqs:
#   - fvm + Flutter SDK resolved (project pins the version).
#   - A booted Android emulator (adb serial like `emulator-5556`), OR
#     a booted iOS simulator (UDID from `xcrun simctl list`).
#   - dart/app/.integration.env populated from .integration.env.example.
#
# Outputs (platform-scoped so Android + iOS runs don't clobber each other):
#   flows        → screenshots/<platform>/failures/<label>.png on failure.
#   screenshots  → screenshots/<platform>/raw/0[1-5]_*.png (five store shots).
# where <platform> is `android` or `ios`, auto-detected from the device id
# (or forced via `PLATFORM=ios scripts/integration.sh …`).
#
# Mechanism:
#   patrol test runs on the device. The Dart test prints
#   `[patrol] SCREENSHOT <subdir> <name>` at each screenshot stop, then
#   sleeps long enough for this script to see the line and shoot the
#   screen via `adb exec-out screencap -p` (Android) or
#   `xcrun simctl io <udid> screenshot` (iOS).

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
DEVICE_ID=""
if [[ $# -ge 1 ]]; then
  DEVICE_ARGS=(-d "$1")
  DEVICE_ID="$1"
fi

# ── Platform detection ────────────────────────────────────────────────────
# Override: `PLATFORM=ios` / `PLATFORM=android` — useful when autodetect
# can't decide (e.g. no device argument given and both an adb emulator and
# a booted iOS sim are present).
# Autodetect: if the id matches a running `adb devices` entry → android;
# if it matches a `simctl list` entry → ios; otherwise fall back to android
# for back-compat with the previous android-only workflow.
PLATFORM="${PLATFORM:-}"
if [[ -z "$PLATFORM" ]]; then
  if [[ -n "$DEVICE_ID" ]] \
     && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' \
        | grep -qx "$DEVICE_ID"; then
    PLATFORM="android"
  elif [[ -n "$DEVICE_ID" ]] \
       && xcrun simctl list devices 2>/dev/null | grep -q "$DEVICE_ID"; then
    PLATFORM="ios"
  else
    PLATFORM="android"
  fi
fi

SHOT_DIR="screenshots/$PLATFORM"
mkdir -p "$SHOT_DIR/raw" "$SHOT_DIR/failures"

echo "[integration.sh] platform=$PLATFORM device='${DEVICE_ID:-<default>}' shots=$SHOT_DIR"

# Awk stream filter: on every `[patrol] SCREENSHOT <subdir> <name>` line,
# take a screenshot of the booted device and write it to
# $SHOT_DIR/<subdir>/<name>.png. All other lines pass through so the
# developer still sees the `[patrol]` step log in real time.
#
# Anchor on the SCREENSHOT keyword rather than fixed positional fields —
# `flutter test --show-flutter-logs` / `patrol` prepends a timestamp +
# `: ` (and sometimes thread prefixes) to each stdout line, which used to
# shift $3/$4 and leave every capture writing to the wrong path.
#
# Screencap tool is platform-conditional:
#   - android: `adb -s <serial> exec-out screencap -p > <path>`
#   - ios:     `xcrun simctl io <udid> screenshot <path>`
# Pass `-s <serial>` on adb so it works when multiple devices are attached
# (bare `adb` otherwise exits 255 with "more than one device/emulator").
ADB_OPTS=""
if [[ "$PLATFORM" == "android" && -n "$DEVICE_ID" ]]; then
  ADB_OPTS="-s $DEVICE_ID"
fi
SCREENCAP_AWK='
BEGIN {
  platform  = ENVIRON["PLATFORM"]
  adb_opts  = ENVIRON["ADB_OPTS"]
  device_id = ENVIRON["DEVICE_ID"]
  shot_dir  = ENVIRON["SHOT_DIR"]
}
/\[patrol\] SCREENSHOT / {
  subdir = ""
  name = ""
  for (i = 1; i <= NF; i++) {
    if ($i == "SCREENSHOT") {
      subdir = $(i + 1)
      name = $(i + 2)
      break
    }
  }
  if (subdir == "" || name == "") {
    print "[screencap] WARN: could not parse marker: " $0
    fflush()
    next
  }
  outfile = shot_dir "/" subdir "/" name ".png"
  # Write to a tempfile first so a failed screencap (e.g. adb exit 255 when
  # multiple devices are attached and -s is missing, or simctl boot not
  # complete) does not leave a 0-byte PNG behind — the shell redirect
  # truncates the target the moment the pipeline starts, before adb has
  # produced any bytes. Rename on success, delete on failure.
  tmpfile = outfile ".tmp"
  if (platform == "ios") {
    # `xcrun simctl io … screenshot` intermittently errors with
    # `Timeout waiting for screen surfaces` while the simulator is
    # mid-transition (a new XCUIApplication launch, keyboard frame
    # change, etc.). Wrap it in a small retry loop so a transient error
    # does not drop a screenshot from the store set.
    sim = (device_id == "" ? "booted" : "\"" device_id "\"")
    # Delegate to the _ios_screencap shell helper defined below the awk
    # block. It brings Simulator.app forward via osascript and retries
    # `xcrun simctl io … screenshot` up to 15 times. Keeping the
    # osascript / shell quoting in a real function avoids fighting
    # nested single quotes inside this awk string.
    cmd = "_ios_screencap " sim " \"" tmpfile "\""
  } else {
    cmd = "mkdir -p \"" shot_dir "/" subdir "\" && adb " adb_opts \
          " exec-out screencap -p > \"" tmpfile "\""
  }
  rc = system(cmd)
  if (rc != 0) {
    system("rm -f \"" tmpfile "\"")
    print "[screencap] ERROR rc=" rc " " outfile
  } else {
    system("mv -f \"" tmpfile "\" \"" outfile "\"")
    print "[screencap] wrote " outfile
  }
  fflush()
  next
}
{ print; fflush() }
'
export ADB_OPTS PLATFORM DEVICE_ID SHOT_DIR

# iOS screencap helper called from the awk filter. Takes
# (sim, tmpfile-basename-ending-in-.png.tmp). `xcrun simctl io …
# screenshot` infers the output format from the file extension, and
# refuses anything other than png/jpg/tiff/bmp — so we write to a
# sibling `.png` tempfile first, then rename that to the caller's
# `.png.tmp` slot (which awk then `mv`s into place on success).
# Encapsulated out-of-line rather than inlined in the awk string so we
# can quote AppleScript / shell freely without fighting the awk-in-
# single-quote nesting.
_ios_screencap() {
  local sim="$1" out="$2" tmp err dir
  # simctl io refuses relative paths when the target filename contains
  # multiple dots (it misreads `screenshots/ios/raw/foo.capture.png` as a
  # missing folder named `foo.capture.png`). Resolve to absolute first.
  dir=$(cd "$(dirname "$out")" && pwd)
  mkdir -p "$dir"
  out="$dir/$(basename "$out")"
  tmp="${out%.tmp}.capture.png"
  # Nudge Simulator.app to the foreground so its display is rendering.
  # `simctl io … screenshot` fails with `Timeout waiting for screen
  # surfaces` when the Simulator window is hidden or minimised. No-op
  # when Simulator is already front.
  osascript -e 'tell application "Simulator" to activate' \
    >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if err=$(xcrun simctl io "$sim" screenshot "$tmp" 2>&1 >/dev/null); then
      if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$out"
        return 0
      fi
    fi
    rm -f "$tmp"
    sleep 1
  done
  echo "_ios_screencap: last error: $err" >&2
  return 1
}
export -f _ios_screencap

# Wipe MITxxx's state on the iOS sim before a run. Without this,
# FlutterSecureStorage's keychain-backed cookie jar survives even
# patrol's `--uninstall` (which only removes the `.app` bundle + its
# data container), so the app starts in a logged-in state and the
# onboarding/login screens the screenshot test expects never appear.
#
# We uninstall the app + keychain-reset the sim. Both commands work on
# a booted simulator in ~0.5 s each — much cheaper than a full
# `simctl erase` which factory-resets the whole sim (~20 s boot).
#
# Bundle ids must match `PRODUCT_BUNDLE_IDENTIFIER` in the dev flavor
# config: `app.omnilect.dev` (main app) and `app.omnilect.RunnerUITests`
# (patrol's UI-test host).
if [[ "$PLATFORM" == "ios" && -n "$DEVICE_ID" ]]; then
  echo "[integration.sh] wiping iOS app state on $DEVICE_ID"
  xcrun simctl uninstall "$DEVICE_ID" app.omnilect.dev \
    >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEVICE_ID" app.omnilect.RunnerUITests \
    >/dev/null 2>&1 || true
  xcrun simctl keychain "$DEVICE_ID" reset >/dev/null 2>&1 || true
fi

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
    --show-flutter-logs \
    "${DEVICE_ARGS[@]+"${DEVICE_ARGS[@]}"}" \
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
  echo "Screenshot PNGs in: $(pwd)/$SHOT_DIR/raw/"
  ls -1 "$SHOT_DIR/raw/" 2>/dev/null || true
else
  echo "Failure PNGs (if any) in: $(pwd)/$SHOT_DIR/failures/"
  ls -1 "$SHOT_DIR/failures/" 2>/dev/null || true
fi

exit "$STATUS"
