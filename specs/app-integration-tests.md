# App Integration Tests Specification

> **Version**: 1.0 (April 2026)
> **Status**: Implemented
> **Last Updated**: 2026-04-20

## Description

Building on the work done on the screenshot automation, we want a suite of
integration tests running against a real emulator, covering the critical
end-to-end flows the app ships. Each run starts from a blank slate install
and drives the app the same way a new user would: log in, choose course
lists, wait for the initial sync, open a course, open a lecture, play its
video, go back to settings, change the list selection, and verify that the
set of synced courses changes in response.

The test is implemented in **patrol** so we can tap the real Keycloak
WebView natively (retiring the `SCREENSHOT_MODE` auto-submit hack). The
existing screenshot harness is migrated onto the same patrol
infrastructure in the same iteration.

## Goals

- One linear end-to-end test that exercises the app's critical-path flows
  against real MITx servers on a real Android emulator.
- Every run starts from a clean install — no leftover auth, sync state,
  Hive boxes, or cached video.
- Use patrol so there is a single, coherent way to drive Flutter UI and
  native/WebView surfaces across both the screenshot harness and the
  integration tests.
- Shared helper library so both harnesses stay in lockstep.
- Screenshot-on-failure for debuggability.

## Non-Goals

- **iOS coverage.** Android emulator only in this iteration; iOS parity is
  a follow-up.
- **CI automation.** Local developer runs only — no GitHub Actions
  integration, no device farm. CI comes later.
- **Offline-mode flows.** Airplane-mode playback is covered by the
  `app-true-offline` spec, not here.
- **Error-path testing.** No bad-password, network-failure, or
  expired-token flows. Happy path only.
- **Accessibility assertions.** No semantic-tree / screenreader / contrast
  checks.
- **Physical devices.** Emulator only for the automated suite.

## Test Framework & Infrastructure

- **Driver:** [patrol](https://pub.dev/packages/patrol). Replaces the
  plain `flutter_test` + `integration_test` harness currently in
  `dart/app/integration_test/screenshots_test.dart`.
- **Why patrol:** native-side automation (UIAutomator on Android) lets
  the test tap the real Keycloak Identity-Provider WebView, so the
  `ScreenshotMode` auto-submit path in
  `dart/app/lib/core/screenshots/screenshot_mode.dart` goes away. One
  way to drive the app everywhere.
- **Runtime:** local Android emulator. iOS simulator is out of scope for
  v1 but the code should not rely on Android-specific Dart APIs beyond
  what patrol already abstracts.
- **Flavor:** `dev` (same as the screenshot harness today).
- **Invocation:** `patrol test` (Patrol's own CLI) — wrapped by a
  replacement for `dart/app/scripts/screenshots.sh`.

## Blank Slate Strategy

- **Before every run, fully uninstall the app:**
  `adb uninstall <applicationId>` for the `dev` flavor.
- `patrol test` reinstalls the app, so the next launch hits first-run
  code paths (onboarding disclosure, empty Hive boxes, no secure-storage
  entries, no cached video).
- No in-Dart reset flag — uninstall is the source of truth. This avoids
  adding a test-only code path that could drift from the real first-run
  behaviour.
- Android emulator has no keychain, so uninstall is sufficient to clear
  `flutter_secure_storage`-backed tokens. When iOS is added later this
  strategy must be revisited.

## Test Data & Credentials

All test inputs come from a single gitignored env file that sits next to
the code, loaded by the run script in the same way
`dart/app/scripts/screenshots.sh` loads `.screenshots.env` today.

- **File:** `dart/app/.integration.env` (renamed from `.screenshots.env`;
  `.integration.env.example` checked in as a template).
- **Account:** a dedicated MITx test account enrolled in the courses
  referenced below.

Required variables:

| Variable | Purpose |
|---|---|
| `INTEGRATION_EMAIL` | Keycloak email for the test account. |
| `INTEGRATION_PASSWORD` | Keycloak password. |
| `INTEGRATION_LIST_NAMES` | Comma-separated display names of MIT Learn lists to tick in the initial list-selection step. |
| `INTEGRATION_LIST_NAMES_ALT` | Comma-separated display names of the *alternate* list set used by the swap-selection step. Must yield a course tile set distinct from `INTEGRATION_LIST_NAMES`. |
| `INTEGRATION_COURSE_TITLE` | Display title of the course tile to open on the home screen. Must be a course that appears under `INTEGRATION_LIST_NAMES`. |
| `INTEGRATION_LECTURE_TITLE` | Display title of the lecture tile to open inside that course's outline. Must match the `Lecture <n>` convention and be a lecture the test account can sync in a reasonable window. |

All variables are injected via `--dart-define` by the run script, mirroring
today's screenshot harness.

## Explicit Test Case — `flows_test.dart`

Single linear `patrolTest` named "blank-slate critical flow". The test
mega-sequence below runs in order; any failure halts subsequent steps and
triggers the failure screenshot path in the Reporting section.

Step numbering aligns with the five screenshot stops today so the
migration is easy to trace.

### 0. Pre-launch (shell, not Dart)

1. Run script calls `adb uninstall <applicationId>` (ignore "not
   installed" errors on a fresh emulator).
2. `patrol test --flavor=dev --dart-define=...` installs + launches.

### 1. Onboarding disclosure

1. Wait for the disclosure screen's **"I understand"** button to be
   tappable.
2. Tap **"I understand"**.
3. Assert the logged-out home appears (see step 2).

### 2. Logged-out home → login sheet

1. Wait for the **"Log in to sync"** button.
2. Tap **"Log in to sync"**.
3. Wait for the Keycloak WebView to be present.

### 3. Keycloak SSO login (native WebView)

1. patrol native-taps the email field; types `$INTEGRATION_EMAIL`.
2. patrol native-taps the password field; types `$INTEGRATION_PASSWORD`.
3. patrol native-taps the submit button.
4. Wait for the list-selection screen title **"Choose what to sync"**
   (up to 2 minutes — covers Keycloak → mitxonline → LMS OAuth2
   round-trip).

### 4. Initial list selection

1. Wait for at least one `Checkbox` on the list-selection screen (the
   available-lists refresh can lag behind the title).
2. For each name in `INTEGRATION_LIST_NAMES`:
    - Find the list tile by text.
    - Tap the tile's checkbox (assert it transitions to checked).
3. Tap the **Continue** `FilledButton` (wait for it to become enabled
   first — it is disabled until at least one checkbox is ticked).

### 5. Initial sync + home (baseline)

1. Wait for the **"My Courses"** app bar.
2. Wait for at least one `_CourseTile` (sync populates the tile list;
   timeout 5 minutes, matching the current harness).
3. Capture the set of visible `_CourseTile` titles → **`baselineTiles`**.
4. Assert `baselineTiles` is non-empty.

### 6. Open target course

1. Find the `_CourseTile` whose title text equals
   `INTEGRATION_COURSE_TITLE`. Fail fast if not present in
   `baselineTiles`.
2. Tap it.
3. Wait for at least one `_SequenceTile` in the outline.

### 7. Open target lecture

1. Locate the `_SequenceTile` whose title matches
   `INTEGRATION_LECTURE_TITLE` (the existing `Lecture <n>` convention).
2. Wait for that tile to render a descendant `DownloadButton` — the
   signal that its content has finished syncing. Timeout 15 minutes
   (same as current harness); unsynced tiles only snackbar "Queued" on
   tap.
3. Tap the tile.

### 8. Video playback

1. Wait for a `Chewie` or `VideoPlayer` widget in the tree.
2. Pump ~3 seconds so the player is past its initial loading frame.
3. **Assertion:** the widget exists. (Advancing-position / no-error
   assertions are explicitly out of scope for v1.)

### 9. Back to settings

1. Navigate back out of the lecture → back out of the course outline →
   land on the home screen.
2. Open Settings from the home app bar / nav.
3. From Settings, navigate to the Courses screen
   (`CoursesScreen`, which is the settings-side entry point to the list
   selection UI).

### 10. Swap list selection

1. On the list-selection screen, for each name currently in
   `INTEGRATION_LIST_NAMES`: tap the checkbox to deselect (assert it
   transitions to unchecked).
2. For each name in `INTEGRATION_LIST_NAMES_ALT`: tap the checkbox to
   select (assert it transitions to checked).
3. Tap **Continue** / confirm.

### 11. Observe synced-list change

1. Back on "My Courses", wait for the tile set to change. Specifically:
   wait until the set of `_CourseTile` titles is non-empty **and**
   different from `baselineTiles`, with timeout 5 minutes.
2. Capture **`postSwapTiles`**.
3. **Assertions:**
   - `postSwapTiles != baselineTiles`.
   - `postSwapTiles` contains at least one title that was not in
     `baselineTiles` (proves the alt list added courses, not just
     removed them).
   - `postSwapTiles` is non-empty.

## Assertions & Observability

- **UI only.** All assertions use `WidgetTester` / patrol finders on
  rendered widgets (`_CourseTile`, `_SequenceTile`, `Checkbox`,
  `FilledButton`, `Chewie`/`VideoPlayer`, text content). No reaching
  into providers/blocs; no opening Hive boxes from the test.
- **Reason:** keeps the test decoupled from internal state types. If the
  UI is wrong, the test should fail — that is what users see.
- **Swap verification is UI-only** (`_CourseTile` title set before vs
  after). Internal-state / disk assertions are deliberately not added.

## Flakiness & Timing Policy

- **No retries.** A failure is a failure. Reruns are a manual developer
  decision.
- **Long single-shot timeouts**, mirroring the current harness:
  - Interaction waits: 30 s.
  - Login round-trip: 2 min.
  - Initial sync to first course tile: 5 min.
  - Synced lecture tile: 15 min.
  - Post-swap tile-set change: 5 min.
  - Overall test timeout: 30 min.
- `_waitFor`-style helpers (port of the existing ones in
  `screenshots_test.dart`) emit a `[patrol]`-prefixed log line every
  ~5 s while waiting so a stuck run is visible in stdout.

## Test Organization

- **One file:** `dart/app/integration_test/flows_test.dart`.
- **One `patrolTest`:** "blank-slate critical flow".
- **One uninstall** per run, performed by the shell script before
  `patrol test` starts.
- Shared helpers live in
  `dart/app/integration_test/support/` (see Key Files), consumed by both
  `flows_test.dart` and the migrated `screenshots_test.dart`.

## Reporting

- **Step-by-step stdout log.** Preserve the existing
  `[screenshots] <step>` pattern (renamed to `[patrol] <step>`), so a
  developer watching the terminal sees which stage the run is in.
- **Screenshot on failure.** A `try { ... } catch` wrapping the test
  body calls `binding.takeScreenshot('failure_<step>')` and writes to
  `dart/app/screenshots/failures/`; failure is then rethrown so the
  test actually fails.
- **Stop on first failure.** The linear structure already gives this —
  no retry loop, no continuation past an exception.
- JUnit XML, video recording, and markdown summaries are out of scope
  for v1.

## Error Handling

- **Missing env vars:** run script exits non-zero with a clear message
  naming the missing variable (same pattern as `screenshots.sh` today).
- **App already installed:** `adb uninstall` ignores the "not installed"
  error so a fresh emulator works without manual setup.
- **Wrong env account:** if the account lacks `INTEGRATION_LIST_NAMES`
  or the target course/lecture, the test fails at the corresponding
  step with a message that names the missing tile.
- **Transient framework errors** caught by `FlutterError.onError` /
  `PlatformDispatcher.instance.onError`: log and continue, matching
  current screenshot-harness behaviour. Assertion failures still
  propagate normally.

## Deployment / Rollout

- No production rollout — this is a developer-only harness.
- No feature flag required.
- The `SCREENSHOT_MODE` compile-time flag and the
  `dart/app/lib/core/screenshots/screenshot_mode.dart` file are removed
  in the same change that migrates the screenshot harness onto patrol.

## Key Files Reference

New:

- `dart/app/pubspec.yaml` — add `patrol` dev dependency.
- `dart/app/integration_test/flows_test.dart` — new mega-flow test.
- `dart/app/integration_test/support/steps.dart` — shared `_waitFor`,
  `_step`, `_byTypeName`, failure-screenshot helpers.
- `dart/app/integration_test/support/env.dart` — typed accessors for
  `INTEGRATION_*` `--dart-define` values.
- `dart/app/scripts/integration.sh` — run script (uninstall + `patrol
  test`), based on today's `screenshots.sh`.
- `dart/app/.integration.env.example` — committed template.
- `dart/app/screenshots/failures/` — failure-screenshot output dir
  (gitignored).

Modified:

- `dart/app/integration_test/screenshots_test.dart` — rewritten on top
  of `support/` and driven by patrol; keeps the five-stop structure.
- `dart/app/scripts/screenshots.sh` — updated to use `patrol test` (or
  folded into `integration.sh` as a mode flag).
- `dart/app/.gitignore` — add `.integration.env` and
  `screenshots/failures/`.

Removed:

- `dart/app/lib/core/screenshots/screenshot_mode.dart` — no longer
  needed; patrol drives the Keycloak WebView natively.
- All `SCREENSHOT_MODE` / `ScreenshotMode.isActive` references in
  `login_screen.dart` and elsewhere.

Referenced (not modified):

- `dart/app/lib/main.dart` (`bootstrap()`).
- `dart/app/lib/flavor_config.dart`.
- List-selection and Courses settings screens (internal widget names:
  `Choose what to sync` title, `CoursesScreen`).

## Implementation Plan (ordered)

1. **PR 1 — Migrate the screenshot harness to patrol.**
   - Add `patrol` dependency.
   - Create `integration_test/support/` helper lib.
   - Rewrite `screenshots_test.dart` on patrol; drive Keycloak via
     native taps instead of `SCREENSHOT_MODE`.
   - Delete `screenshot_mode.dart` and its call sites.
   - Update `scripts/screenshots.sh` (or introduce
     `scripts/integration.sh`) to invoke `patrol test`.
   - Verify five PNG screenshots still land in
     `dart/app/screenshots/raw/`.
2. **PR 2 — Add blank-slate uninstall + env-var scaffolding.**
   - Rename `.screenshots.env` → `.integration.env`; add new
     `INTEGRATION_LIST_NAMES`, `INTEGRATION_LIST_NAMES_ALT`,
     `INTEGRATION_COURSE_TITLE`, `INTEGRATION_LECTURE_TITLE`.
   - Run script performs `adb uninstall` before `patrol test`.
   - `.integration.env.example` checked in.
3. **PR 3 — Add the mega-flow integration test.**
   - `integration_test/flows_test.dart` implementing steps 1–11
     above, using `support/steps.dart` helpers.
   - Failure-screenshot wrapper.
   - Run end-to-end against the test account; confirm stable.

## Open Follow-ups (explicitly deferred)

- iOS simulator parity.
- GitHub Actions CI wiring + secret management.
- Video-playback assertions beyond widget presence
  (position advances, no controller error).
- Offline/airplane-mode flows.
- Per-flow test split once the suite outgrows a single file.

## Implementation Notes

**Implemented**: April 2026

**Key changes**:

- Added `patrol` + `patrol_cli` to `dart/app/pubspec.yaml` dev_dependencies.
- New shared support lib at `dart/app/integration_test/support/`:
  - `env.dart` — typed `INTEGRATION_*` accessors.
  - `steps.dart` — `waitFor` / `waitUntil` / `byTypeName` / `suppressFrameworkErrors` / `runWithFailureScreenshot` / `keycloakLogin` / `captureScreenshot`.
- New mega-flow test `dart/app/integration_test/flows_test.dart` implementing
  the eleven-step blank-slate critical flow.
- `screenshots_test.dart` rewritten on top of patrol + the new support lib;
  the five store PNGs keep the same names (`01_onboarding` … `05_lecture`).
- `dart/app/scripts/integration.sh` is the single run script with a `flows`
  (default) / `screenshots` mode flag. `scripts/screenshots.sh` is a thin
  shim for backwards compatibility.
- `.integration.env.example` checked in; `.screenshots.env.example` removed.
  Developers migrate `.screenshots.env` → `.integration.env` locally.
- `dart/app/lib/core/screenshots/screenshot_mode.dart` deleted, along with
  all `SCREENSHOT_MODE` / `ScreenshotMode` call-sites in `main.dart` and
  `login_screen.dart`. Keycloak is now driven natively via patrol.
- `dart/app/test_driver/integration_test.dart` removed — patrol does not
  use `flutter drive`, so the extended driver is dead code.
- `dart/app/.gitignore` now ignores `/screenshots/failures/` alongside
  `/screenshots/raw/`.

**Deviations from spec**:

- **Screenshot capture mechanism.** `patrol` 4.5.0 does not expose
  `binding.takeScreenshot()` — its `PatrolBinding` extends
  `LiveTestWidgetsFlutterBinding`, not `IntegrationTestWidgetsFlutterBinding`,
  so there is no on-device callback for pulling PNG bytes to the host.
  Instead, the Dart test prints a `[patrol] SCREENSHOT <subdir> <name>`
  marker line and sleeps 1.5 s; `scripts/integration.sh` tails stdout via
  `awk` and runs `adb exec-out screencap -p > screenshots/<subdir>/<name>.png`.
  The failure-screenshot path uses the same mechanism with
  `subdir=failures`. As a consequence, the helpers no longer require
  `IntegrationTestWidgetsFlutterBinding.convertFlutterSurfaceToImage()`
  or an extended test driver.
- **Blank-slate uninstall.** Relies on `patrol test`'s own default
  `--uninstall` behaviour (adb-uninstall before + after) rather than an
  explicit `adb uninstall` in the run script. The effect is identical
  (fresh install every run) with one less thing for the script to own.
- **List toggling.** The test taps the whole `CheckboxListTile` rather
  than its leading `Checkbox` subwidget. Both paths toggle the selection
  identically (per `list_picker.dart`) and the tile is a bigger hit target
  for the patrol native tap, which makes the tests more robust.
