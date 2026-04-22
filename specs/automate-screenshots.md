# Automate Screenshots Specification

> **Version**: 1.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-22

## Summary / Goal

Turn the raw PNGs produced by the app's Patrol integration tests into
store-ready marketing screenshots — "device frame + headline on a branded
background" — for the App Store (iPhone 6.9") and Google Play (Android
phone), and wire the packaged output into Fastlane so the existing
`release` lane uploads them.

Pipeline contract:

- **One command** to go from raw PNGs → packaged screenshots for every
  target canvas.
- **Deterministic** — same raw PNGs + same templates produce
  byte-identical output so PRs that change only copy are reviewable via
  diff.
- **No new runtime in the release path beyond Python** — compositor runs
  with the shared `python-tools/requirements.txt` stack.

---

## Scope

### In scope (v1)

- Python + Pillow compositor that reads raw PNGs from
  `dart/app/screenshots/raw/android/` and `dart/app/screenshots/raw/ios/`
  and produces packaged marketing screenshots under
  `dart/app/screenshots/packaged/`.
- Tilted/isometric composition: device frame rotated ~15°, headline +
  subhead alongside, single MIT-red vertical gradient background shared
  across all frames.
- Two canvas sizes for v1:
  - iPhone 6.9" (1290 × 2796) — drives every iOS slot via upscale.
  - Android phone (1080 × 1920, 9:16) — drives every Play Store phone
    slot.
- English-only copy, structured so additional locales are a file drop.
- Light-mode only (current raw captures are light).
- Populating `dart/app/fastlane/metadata/…` with packaged screenshots.
- Flipping `skip_upload_screenshots` + `skip_upload_images` in the
  existing Fastlane `release` lane and adding an `upload_screenshots`
  convenience lane.
- Git LFS for all screenshot PNGs (raw and packaged).
- Deterministic output — pinned Pillow/freetype, committed Inter TTF,
  SHA-256 golden-manifest test.

### Out of scope (v1)

- **iOS capture wiring** — Patrol on iOS simulator is handled in a
  separate spec. This spec assumes that by the time it runs, iOS raw
  captures exist at `dart/app/screenshots/raw/ios/`. The Android capture
  spec is expected to have migrated its output to
  `dart/app/screenshots/raw/android/` by then.
- **iPad 13"**, Android 7"/10" tablet canvases.
- **Dark-mode variants.**
- **Landscape lecture variants** (video player screenshot is portrait).
- **CI wiring.** Composer runs on a developer's machine before cutting a
  release. A lint-only CI job is a cheap follow-up if packaged PNGs start
  drifting.
- **Additional locales** beyond en-US.
- **App Store / Play Store descriptions, keywords, changelogs, feature
  graphic, promo videos.** Those live elsewhere in
  `fastlane/metadata/*/` and are not produced by this pipeline.
- **Marketing-site (omnilect.app) hero images.** The Astro site can pull
  packaged PNGs by reference later; this spec does not restructure that
  pipeline.

---

## Device & Form-Factor Matrix

| Platform | Class | Canvas (px) | Orientation | Required v1 |
|---|---|---|---|---|
| iOS | iPhone 6.9" (15 Pro Max, 16 Pro Max) | 1290 × 2796 | portrait | yes |
| Android | Phone | 1080 × 1920 (9:16) | portrait | yes |
| iOS | iPad 13" | 2064 × 2752 | portrait | deferred |
| Android | 7" / 10" tablet | — | — | deferred |
| Any | Landscape | — | — | deferred |

Both stores accept upscaled screenshots for smaller slots within the
same device class, so one canvas per row covers every required slot on
each store.

The composer schema must make adding a new canvas a single YAML entry
(see `canvases.yaml` below).

---

## Screens to Capture

The five raw captures already driven by
`dart/app/integration_test/screenshots_test.dart` map 1:1 to the five
marketing frames:

| # | Raw PNG stem | Marketing role |
|---|---|---|
| 1 | `01_onboarding` | First impression / unofficial disclosure |
| 2 | `02_list_selection` | Choose what syncs |
| 3 | `03_home` | Library at a glance |
| 4 | `04_course_outline` | Course structure + download state |
| 5 | `05_lecture` | Offline video playback |

Per-store slot order: frames 1→5 in order on both stores. Slot counts
(Play Store max 8, App Store max 10) leave room for future additions.

---

## Marketing Composition & Branding

### Layout — tilted / isometric

- Device frame rotated ~15° around its vertical axis (simulated
  perspective). Headline + subhead stacked to the side of the device,
  vertically centred.
- Frame occupies the right ~55% of the canvas; copy occupies the left
  ~40% with ~5% padding either side.
- Device carries a soft drop shadow onto the gradient.
- One screenshot per marketing frame; no multi-panel layouts.

Tilt direction is consistent across all 5 frames (lean-right) for v1.
Alternating tilt per frame is a polish knob the composer exposes via
`canvases.yaml` but is not used in v1.

### Background

- Vertical gradient from `#A31F34` (MIT red, app primary) at the top to
  `#6B1523` at the bottom, shared across every frame so the store-page
  strip reads as a cohesive sequence.

### Typography

- **Inter** for both headline and subhead, shipped as a committed TTF
  under `python-tools/screenshot-composer/fonts/` (the Astro marketing
  site already uses Inter — reuse the same files rather than bundling a
  second family).
- Headline: Inter Bold.
- Subhead: Inter Regular.
- Point sizes live in `canvases.yaml` per canvas — scale
  proportionally to canvas width.
- Headline colour: `#FFFFFF`. Subhead colour: `#F4D9DD` (muted warm
  tint of the brand red).

### "Unofficial" disclosure

- `UNOFFICIAL` wordmark, top-left of **frame 1 only**, ~18pt (iPhone
  canvas; scale for Android), 70% opacity white. Visible enough to be
  honest, small enough not to dominate the marketing page. Every other
  frame is clean.

### Status bar normalization

The inner screenshot gets its top status-bar strip masked and replaced
with a synthetic one so real time / real battery / notification icons
do not leak:

- iOS canvases: dark 9:41 status bar, full wifi + battery, no
  notification icons.
- Android canvases: 9:41, full wifi + battery, no notification icons.

Implemented as: crop the top N px of the raw PNG (canvas-specific) and
overlay a platform-appropriate rendered status bar PNG before placing
the result into the device frame.

### Composition pipeline per frame

1. Draw gradient background onto the full canvas.
2. Raster headline text block (Inter Bold) into the copy area.
3. Raster subhead text block (Inter Regular) below the headline.
4. Apply status-bar mask + synthetic status bar to the raw PNG.
5. Perspective-transform the masked raw PNG onto the device frame's
   screen quadrilateral (Pillow `Image.transform(..., PERSPECTIVE,
   coeffs)`; the 8 coefficients come from solving the homography from
   the raw PNG's rectangle to the four corner points defined on the
   frame).
6. Composite the tilted device (PNG with bezel already pre-tilted) with
   drop shadow onto the canvas.
7. On frame 1: overlay the `UNOFFICIAL` wordmark top-left.

Exact geometry (copy bounds, device corners in canvas coordinates,
headline point sizes) lives in
`python-tools/screenshot-composer/templates/canvases.yaml`.

---

## Copy & Localization

### Storage

All copy lives in
`python-tools/screenshot-composer/templates/copy/en-US.yaml`:

```yaml
# Keyed by raw PNG stem (without .png).
01_onboarding:
  headline: "TODO: onboarding headline"
  subhead:  "TODO: onboarding subhead"
02_list_selection:
  headline: "TODO: list-selection headline"
  subhead:  "TODO: list-selection subhead"
# … through 05_lecture
```

### Draft status

Every headline and subhead ships as a **TODO placeholder**. The owner
must review and replace the strings before the first
`fastlane upload_screenshots` call. The composer emits a warning (and
exits non-zero under `--strict`) if any value still starts with `TODO:`.

### Adding a locale

Drop `copy/<locale>.yaml` with the same keys. The composer iterates over
every locale file it finds and writes to the matching
`fastlane/metadata/<locale>/` path. No code change required.

---

## Tooling & Pipeline

### Composer location

`python-tools/screenshot-composer/` — one subdirectory per tool is the
repo convention stated in `CLAUDE.md`. Reuses the shared
`python-tools/requirements.txt`.

### Layout

```
python-tools/
  requirements.txt               # pins Pillow + deps shared across tools
  screenshot-composer/
    CLAUDE.md                    # purpose + usage
    package.py                   # entrypoint CLI
    compose.py                   # per-frame composition logic
    fonts/
      Inter-Bold.ttf
      Inter-Regular.ttf
    templates/
      canvases.yaml              # per-canvas geometry
      copy/
        en-US.yaml
      frames/
        iphone_6_9.png           # pre-tilted bezel asset
        android_phone.png
      status_bars/
        ios.png
        android.png
```

### Raw input (produced elsewhere)

```
dart/app/screenshots/
  raw/
    android/
      01_onboarding.png
      …
      05_lecture.png
    ios/
      01_onboarding.png
      …
      05_lecture.png
```

The Android capture path is the existing
`dart/app/scripts/integration.sh screenshots` flow. The iOS capture path
is a separate spec; this spec does not block on it but its happy path
requires iOS PNGs to be present.

### Packaged output

```
dart/app/screenshots/packaged/
  ios/iphone_6_9/en-US/
    01_onboarding.png     # 1290 × 2796
    …
    05_lecture.png
  android/phone/en-US/
    01_onboarding.png     # 1080 × 1920
    …
    05_lecture.png
```

### Commands

```
python3 python-tools/screenshot-composer/package.py                  # all canvases, all locales
python3 python-tools/screenshot-composer/package.py --canvas=iphone_6_9
python3 python-tools/screenshot-composer/package.py --locale=en-US
python3 python-tools/screenshot-composer/package.py --sync-fastlane
python3 python-tools/screenshot-composer/package.py --strict         # fail on any TODO: copy
```

A thin wrapper `dart/app/scripts/screenshots.sh` chains the Android
Patrol capture step with the composer for the "one-command refresh"
case:

```
scripts/screenshots.sh   # = scripts/integration.sh screenshots
                         # + python3 python-tools/screenshot-composer/package.py --sync-fastlane
```

### Git LFS

All screenshot PNGs (raw + packaged + template frames + status bars) are
tracked in Git LFS. `.gitattributes` at the repo root adds:

```
dart/app/screenshots/**/*.png filter=lfs diff=lfs merge=lfs -text
python-tools/screenshot-composer/templates/**/*.png filter=lfs diff=lfs merge=lfs -text
```

Commit includes installing the LFS hook in the contributor's local repo
(`git lfs install`) — document this in the tool's `CLAUDE.md`.

### Error handling

- **Missing raw PNG for a canvas's source platform** → composer exits
  non-zero, lists the missing files, writes nothing for affected
  canvases.
- **TODO: placeholder copy under `--strict`** → exits non-zero.
- **Composer crash mid-batch** → each output PNG is written to `*.tmp`
  first and atomically renamed on success (matches the pattern
  `scripts/integration.sh` already uses).
- **No retries** — failures are developer-fixable, never flaky.

### Who runs it

- **Developer locally**, before cutting a release. Flow:
  capture (Android + iOS) → inspect raw → edit
  `copy/en-US.yaml` → `python-tools/screenshot-composer/package.py
  --sync-fastlane` → commit → `fastlane release` or
  `fastlane upload_screenshots`.
- **Not wired into CI** in v1.

---

## Fastlane / Store Integration

### Metadata layout

```
dart/app/fastlane/metadata/
  en-US/
    description.txt
    keywords.txt
    name.txt
    release_notes.txt
    # iOS screenshots (consumed by `deliver`)
  screenshots/en-US/
    iPhone 6.9 Display/
      1_0_onboarding.png
      2_0_list_selection.png
      3_0_home.png
      4_0_course_outline.png
      5_0_lecture.png
  android/en-US/
    images/
      phoneScreenshots/
        1_onboarding.png
        2_list_selection.png
        3_home.png
        4_course_outline.png
        5_lecture.png
```

- `supply` (Play) expects
  `metadata/android/<locale>/images/phoneScreenshots/`.
- `deliver` (App Store) expects
  `metadata/<locale>/screenshots/<device-display-name>/` with filename
  prefixes controlling order.

`--sync-fastlane` on the composer copies packaged PNGs into both trees
with the correct filenames.

### Fastfile changes

In `dart/app/fastlane/Fastfile`:

- `release_android_impl` → flip `skip_upload_screenshots: true` to
  `false`, `skip_upload_images: true` to `false`.
- `release_ios_impl` → add a `deliver` call with
  `skip_screenshots: false`, `skip_binary_upload: true`,
  `skip_metadata: true` (screenshots only in v1; descriptions / keywords
  follow later).
- `beta` and `dev_distribute` remain untouched.
- Add a convenience lane `upload_screenshots` that runs screenshots-only
  `deliver` + `supply`, so screenshots can be refreshed without a
  binary re-upload.

### Release order

- v1's happy path assumes the Play Store listing exists (it does at
  `app.omnilect`) and the App Store listing may or may not exist
  (marketing site currently says "coming soon"). `upload_screenshots`
  works incrementally — runs `supply` unconditionally, runs `deliver`
  only if the iOS listing is provisioned.

---

## Testing & Reproducibility

### Determinism strategy

- Pillow + freetype pinned in `python-tools/requirements.txt` to exact
  versions.
- Inter TTF files committed at known SHA-256s.
- PNG encoding uses Pillow's default zlib with no metadata / no
  timestamp.
- All random seeds removed (none should exist — callout in code
  review).

### Golden-manifest test

`python-tools/screenshot-composer/tests/test_golden_manifest.py`:

- Regenerates every packaged canvas from committed raw PNGs.
- Asserts the SHA-256 of each output PNG matches a checked-in
  `golden_manifest.json`.
- Any copy change, layout change, or template change flips the manifest
  — reviewers see both the PNG diff (via LFS) and the manifest diff in
  the PR.

### Runs under

`pytest python-tools/screenshot-composer/tests/` — part of whatever
Python test invocation `python-tools/` adopts (this spec does not
mandate a test runner for the wider Python tree).

### `fvm flutter analyze`

No Dart code is added by this spec. Analyzer clean is not affected.

---

## Key Files Reference

### Existing (read by this pipeline)

- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/integration_test/screenshots_test.dart`
  — drives Android raw capture.
- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/scripts/integration.sh`
  — Patrol runner + screencap parsing.
- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/fastlane/Fastfile`
  — release/beta/dev_distribute lanes; today all skip screenshots.
- `/Users/kristian.freed/projects/softmemes/omnilect/web/public/`
  — Astro marketing site; source of truth for brand gradient values
  and Inter typography.
- `/Users/kristian.freed/projects/softmemes/omnilect/CLAUDE.md`
  — repo convention: every Python tool lives in its own subdir under
  `python-tools/`.

### To create

- `python-tools/screenshot-composer/CLAUDE.md`
- `python-tools/screenshot-composer/package.py`
- `python-tools/screenshot-composer/compose.py`
- `python-tools/screenshot-composer/fonts/Inter-{Bold,Regular}.ttf`
- `python-tools/screenshot-composer/templates/canvases.yaml`
- `python-tools/screenshot-composer/templates/copy/en-US.yaml`
- `python-tools/screenshot-composer/templates/frames/{iphone_6_9,android_phone}.png`
- `python-tools/screenshot-composer/templates/status_bars/{ios,android}.png`
- `python-tools/screenshot-composer/tests/test_golden_manifest.py`
- `python-tools/screenshot-composer/tests/golden_manifest.json`
- `dart/app/screenshots/packaged/**` — committed LFS-tracked outputs.
- `dart/app/scripts/screenshots.sh` — one-command wrapper.
- `.gitattributes` at repo root — LFS tracking rules for screenshot
  PNGs.

### To modify

- `python-tools/requirements.txt` — add pinned Pillow + freetype.
- `dart/app/fastlane/Fastfile` — flip `skip_upload_screenshots` /
  `skip_upload_images` in `release_android_impl` + `release_ios_impl`;
  add `upload_screenshots` convenience lane.

---

## Decisions Captured in Refinement

Confirmed with the owner via interactive Q&A (not defaulted):

1. **Composer runtime: Python + Pillow**, located at
   `python-tools/screenshot-composer/`. Rejected alternatives: Dart CLI,
   Fastlane `frameit`, Node + sharp.
2. **Device matrix v1: iPhone 6.9" + Android phone only.** iPad,
   Android tablets, and landscape are deferred.
3. **iOS capture is out of scope for this spec** — handled in a
   separate spec. This compositor consumes
   `dart/app/screenshots/raw/ios/` as if it exists.
4. **Light mode only.** Dark-mode variants deferred.
5. **English only** with locale scaffolding (`copy/<locale>.yaml`) ready
   for more.
6. **Composition style: tilted / isometric** — device rotated ~15°,
   headline beside it. Harder with Pillow (perspective transform) but
   more differentiated than a straight-on frame.
7. **Background: MIT red vertical gradient** (`#A31F34` → `#6B1523`),
   shared across all 5 frames.
8. **"UNOFFICIAL" wordmark on frame 1 only** — small, top-left, 70%
   opacity.
9. **Screen set: keep the current 5 raw captures** (onboarding, list
   selection, home, course outline, lecture). No added or removed
   frames.
10. **Copy is TODO placeholder in v1**; owner must replace before first
    upload. `--strict` mode blocks uploads if any `TODO:` remains.
11. **All screenshot PNGs in Git LFS** — raw, packaged, template frames,
    status bars.
12. **No CI wiring in v1.** Composer runs on the developer's machine
    before release.
13. **Fastlane: flip `skip_upload_screenshots` on `release` lanes in
    this spec** and add a standalone `upload_screenshots` convenience
    lane.
14. **Determinism: pinned Python + Pillow + freetype, committed Inter
    TTF, SHA-256 golden-manifest test.** No Docker.
