# Automate Screenshots Specification

> **Version**: 1.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-22

## Summary / Goal

Turn the raw PNGs produced by the Patrol integration test at
`dart/app/integration_test/screenshots_test.dart` into store-ready marketing
screenshots ("device frame + headline + branded background") for every
size/form-factor the App Store and Google Play require, and wire the results
into Fastlane so the existing `release` lane can upload them.

The pipeline must be:

- **One command** to go from raw PNGs → packaged screenshots for all
  target devices.
- **Deterministic** — same raw PNGs + same templates produce
  byte-identical output so PRs that change only copy are reviewable via
  diff.
- **Hackable by a solo developer** — no paid SaaS, no proprietary
  design-tool step in the release critical path.

> **Note on interactive refinement.** This spec was refined with Auto Mode
> active and the `AskUserQuestion` tool unavailable in the environment.
> Decisions below therefore reflect defaults chosen to match typical
> Flutter indie-app-store practice plus this repo's existing style
> (Fastlane, deterministic tooling, `fvm`-pinned). Each decision is called
> out so it can be overridden before implementation — see **Decisions &
> assumptions** at the bottom.

---

## Scope

### In scope (v1)

- Taking the five raw PNGs already produced by
  `integration_test/screenshots_test.dart` and composing them into
  store-ready marketing screenshots.
- Output sized for the **minimum** required device slots on both stores
  (see device matrix below); upscale/letterbox rather than capturing at
  native sizes per device.
- English-only copy, structured so future locales are additive (keyed
  YAML + per-locale output folders).
- Light-mode only (raw captures are light mode today).
- Populating `fastlane/metadata/android/en-US/images/…` and
  `fastlane/metadata/en-US/…` with the packaged screenshots.
- Flipping the `skip_upload_screenshots` / `skip_upload_images` flags in
  the existing Fastlane `release` lane so uploads happen as part of the
  release flow.
- Deterministic output + a lightweight visual regression check.

### Out of scope (v1, explicitly)

- iOS **capture** — Patrol-on-iOS-simulator wiring stays as a follow-up
  spec. v1 renders iOS marketing screenshots from the **Android**
  captures (scaled to iPhone/iPad canvas sizes with a device frame). If
  and when iOS capture lands, the pipeline swaps the source PNGs without
  changing the composer.
- Dark-mode variants.
- Landscape lecture variants. Current video capture is portrait;
  landscape can be added once the Patrol script supports rotation.
- Play Store **feature graphic** (1024×500) — separate asset, lives
  alongside screenshots later if we want it.
- App Store **promo videos / app previews**.
- App Store / Play Store **descriptions, keywords, changelogs** — those
  live in `fastlane/metadata/*/description.txt` etc. and are not produced
  by this pipeline.
- In-app review prompts.
- Marketing-site hero images on `omnilect.app` — that Astro site can
  re-use the packaged PNGs by reference, but v1 does not restructure the
  site's asset pipeline.

---

## Device & Form-Factor Matrix

Both stores require a single source size per device class and accept
upscaled variants for the other slots in that class, so we render one
canonical canvas per row below and let the stores handle slot-mapping.

| Platform | Class | Canvas (px) | Orientation | Required v1 |
|---|---|---|---|---|
| iOS | iPhone 6.9" (15 Pro Max, 16 Pro Max) | 1290 × 2796 | portrait | yes |
| iOS | iPad 13" (Pro M4) | 2064 × 2752 | portrait | yes |
| Android | Phone | 1080 × 1920 (9:16) | portrait | yes |
| Android | 7" tablet | 1200 × 1920 | portrait | follow-up |
| Android | 10" tablet | 1600 × 2560 | portrait | follow-up |

Rationale for v1 = iPhone 6.9" + iPad 13" + Android phone:

- Apple only **requires** the largest iPhone and largest iPad class now
  (smaller classes accept the larger screenshots upscaled).
- Google Play requires at least two phone screenshots; tablet slots are
  optional and we do not have a tablet UX pass yet.
- Three canvas sizes is the smallest set that covers both stores'
  minimum submission requirements.

**Landscape + tablets** are explicitly deferred; the composer must make
adding a new canvas a matter of one YAML entry (see Tooling).

---

## Screens to Capture

The five raw captures produced today by `screenshots_test.dart` map 1:1
to the five marketing frames for v1. Each gets its own headline/subhead
pair below.

| # | Raw PNG | Marketing frame role | Headline (en-US) | Subhead |
|---|---|---|---|---|
| 1 | `01_onboarding.png` | "Unofficial but honest" | **Your MITx courses, offline.** | Unofficial. MIT-approved URLs, none of the network. |
| 2 | `02_list_selection.png` | Choose what syncs | **Pick the courses you care about.** | Sync only the lists you need — save storage, save data. |
| 3 | `03_home.png` | Library at a glance | **Your library, synced.** | Everything you enrolled in, ready on the plane. |
| 4 | `04_course_outline.png` | Course outline | **Every lecture, downloaded.** | Clear outline. Clear progress. Clear download state. |
| 5 | `05_lecture.png` | Video playback | **Watch anywhere. No signal required.** | Full video + transcripts, cached on device. |

Copy is **draft** — owner must review/replace before first store upload.
Structure below keeps copy separate from composition so edits are one
YAML change.

Per-store slot order:

- **Play Store (max 8):** frames 1, 2, 3, 4, 5 in that order. Slots 6–8
  left empty for now.
- **App Store (max 10):** same 5 frames in the same order. Slots 6–10
  left empty.

---

## Marketing Composition & Branding

### Style

- **Device frame:** realistic-looking bezel. Reuse a public-domain /
  permissively-licensed frame set (Apple's publicly shipped device
  mockups for iPhone/iPad; a neutral Pixel-style frame for Android).
  Store the frame PNGs under
  `dart/app/screenshots/templates/frames/`.
- **Layout:** one screenshot per frame (no multi-panel). Portrait-only
  for v1.
- **Position:** device frame occupies the lower ~60–70% of the canvas,
  headline + subhead stacked above. Slight drop shadow on the device.
- **Background:** vertical gradient from `#A31F34` (MIT red, brand
  primary) at the top to a darker `#6B1523` at the bottom. Single
  gradient shared across all 5 frames keeps the strip visually
  cohesive on the store page.
- **Type:** Inter (already used by the Astro marketing site — reuse the
  same font files rather than bundling a second family). Headline:
  Inter Bold, ~72pt on iPhone canvas, scaled proportionally on iPad and
  Android. Subhead: Inter Regular, ~36pt.
- **Color of text on background:** white `#FFFFFF` for headline,
  `#F4D9DD` (muted warm tint) for subhead.
- **"Unofficial" disclosure:** small `UNOFFICIAL` wordmark top-left of
  frame 1 only, 18pt, 70% opacity. Keeps the "not endorsed by MIT"
  obligation visible without repeating on every slide.

### Status bar normalization

The Android emulator's status bar in the raw capture shows real time /
real signal icons. The composer **masks the top status bar strip** of
the inner screenshot with a synthetic, clean status bar:

- iOS canvases: Apple's canonical 9:41 dark status bar.
- Android canvases: 9:41 with full wifi + full battery + no notification
  icons.

This is done by cropping the top 24px of the raw capture and overlaying
a platform-appropriate rendered status bar PNG.

### Per-screen composition rules

The composer renders each frame by stacking:

1. Gradient background (full canvas).
2. Headline text block (anchored top, centered horizontally, with
   padding defined per canvas).
3. Subhead text block (below headline).
4. Device frame PNG (anchored bottom, centered).
5. Raw screenshot PNG (clipped to the frame's screen area, with
   status-bar mask applied).

Exact padding/size values live in
`dart/app/screenshots/templates/canvases.yaml`.

---

## Copy & Localization

### Storage

All copy lives in
`dart/app/screenshots/templates/copy/en-US.yaml`:

```yaml
# Keyed by raw PNG stem (without .png).
01_onboarding:
  headline: "Your MITx courses, offline."
  subhead:  "Unofficial. MIT-approved URLs, none of the network."
02_list_selection:
  headline: "Pick the courses you care about."
  subhead:  "Sync only the lists you need — save storage, save data."
# …
```

Adding a locale = adding `copy/<locale>.yaml` with the same keys plus
the `fastlane/metadata/<locale>/` folder. The composer iterates over
every locale file it finds.

### Author

First-pass copy in this spec is written by the implementer/owner. Not
shipped to any store until the owner has explicitly reviewed it in the
packaged output — the spec does **not** auto-promote. This is enforced
by keeping the upload step behind the existing Fastlane `release` lane
(manual trigger).

---

## Tooling & Pipeline

### Composer

Implemented in **Dart** as a headless CLI under `dart/app/tool/screenshots/`.

Rationale:

- The repo is already a Flutter project with `fvm`-pinned Dart; no new
  runtime.
- Dart's `package:image` handles PNG decode/encode + resize + crop. For
  text rendering we use `package:image`'s bitmap-font drawing, OR — if
  we want nicer glyphs — render each text block once with
  `package:pdf`/`package:printing`'s text layout and rasterize, OR
  simplest: pre-render the headline/subhead for each
  (screen × canvas × locale) tuple via a tiny Flutter widget test in
  `tool/screenshots/render_text.dart` that uses the real Flutter text
  engine and dumps PNG strips. We pick the **widget-test route** because
  it gives us Material 3 + Inter typography for free and stays
  deterministic (golden-file compatible).
- Keeps the composer testable with Dart's own test framework.
- Avoids pulling in Node, Python, or a design tool into the release
  critical path.

Alternative considered: `fastlane frameit`. Rejected because frameit's
templating is awkward for per-slide custom copy + gradient backgrounds,
and it's a Ruby gem layer we'd otherwise not need.

### Inputs

```
dart/app/screenshots/
  raw/                      # produced by screenshots_test.dart
    01_onboarding.png
    …
  templates/
    frames/
      iphone_6_9.png
      ipad_13.png
      android_phone.png
    canvases.yaml           # per-canvas geometry
    copy/
      en-US.yaml
```

### Outputs

```
dart/app/screenshots/packaged/
  ios/
    iphone_6_9/en-US/
      01_onboarding.png   # 1290x2796
      …
    ipad_13/en-US/
      …
  android/
    phone/en-US/
      01_onboarding.png   # 1080x1920
      …
```

Packaged PNGs are **committed to git** (small number of files, ~5 × 3
canvases × 1 locale = 15 files, each <1 MB). Commit means reviewers can
see the screenshots in the PR diff. Regenerating locally with the
pipeline should be a no-op diff.

### Commands

```
fvm dart run tool/screenshots/package.dart          # all canvases, all locales
fvm dart run tool/screenshots/package.dart --canvas=iphone_6_9
fvm dart run tool/screenshots/package.dart --locale=en-US
fvm dart run tool/screenshots/package.dart --sync-fastlane
```

`--sync-fastlane` additionally copies the packaged outputs into the
Fastlane metadata tree (see next section).

A thin wrapper `scripts/screenshots.sh` chains the existing Patrol
capture step with the composer, for the "one-command refresh" case:

```
scripts/screenshots.sh      # = scripts/integration.sh screenshots
                            # + tool/screenshots/package.dart --sync-fastlane
```

### Error handling

- **Missing raw PNG** → composer exits non-zero and lists which files
  are missing; no partial output is written.
- **Composer crash mid-batch** → each canvas writes to `*.tmp` first and
  atomically renames on success, matching the pattern the awk filter
  already uses in `scripts/integration.sh`.
- **No retries** — failures are always developer-fixable, never
  flaky-infra.

### Who runs it

- **Developer locally, before cutting a release.** The flow is:
  `scripts/integration.sh screenshots` → inspect raw → edit copy if
  needed → `scripts/screenshots.sh` → commit → `fastlane release`.
- **Not wired into CI on every PR** in v1. A follow-up can add a
  `lint_screenshots` CI job that re-runs the composer on the committed
  raw PNGs and fails if the packaged output drifts.

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
  # iOS screenshots (supply must default-pick these)
  screenshots/en-US/
    iPhone 6.9 Display/
      1_0_onboarding.png
      2_0_list_selection.png
      …
    iPad Pro (6th generation)/
      1_0_onboarding.png
      …
  android/en-US/
    images/
      phoneScreenshots/
        1_onboarding.png
        2_list_selection.png
        …
```

(The Fastlane `supply` action expects Play Store images under
`metadata/android/<locale>/images/phoneScreenshots/`. The Fastlane
`deliver` action expects App Store screenshots under
`metadata/<locale>/screenshots/<device-display-name>/`.)

`--sync-fastlane` copies from `screenshots/packaged/…` into both
destinations with the correct filenames.

### Fastfile changes

In `dart/app/fastlane/Fastfile`:

- `release_android_impl` → flip `skip_upload_screenshots: true` to
  `false`, and `skip_upload_images: true` to `false`.
- `release_ios_impl` → switch from `upload_to_testflight` to
  `deliver` (or keep testflight for binary + add a `deliver`
  screenshots-only call) with `skip_screenshots: false`,
  `skip_binary_upload: true`, `skip_metadata: true` (screenshots only
  in v1 — descriptions come later).
- Leave `beta` / `dev_distribute` alone (they don't need screenshots).
- Add a convenience lane `upload_screenshots` that runs `deliver` +
  `supply` with screenshots-only flags, so screenshots can be refreshed
  without a binary re-upload.

The existing flow (`beta` pushes to TestFlight without touching
screenshots) is preserved.

### Android first, iOS follows

Since the App Store listing doesn't exist yet (marketing site says
"coming soon"), v1's happy path is:

1. Generate all three canvases.
2. `fastlane upload_screenshots_android` publishes to the existing Play
   listing.
3. iOS packaged screenshots are committed to the repo and ready for the
   day the App Store listing is created; `upload_screenshots_ios` runs
   at that point.

---

## Testing & Reproducibility

### Determinism

- Composer uses fixed seeds (no randomness anywhere).
- Text rendering via Flutter widget-test golden path: identical across
  machines once `fvm` pins the Flutter version (already the case).
- PNG encode uses `package:image`'s default (no metadata, no
  timestamp).
- Output hash stability tested in
  `dart/app/test/tool/screenshots_golden_test.dart`: asserts SHA-256 of
  every packaged PNG matches a checked-in manifest. Breaking the
  manifest is an intentional act — reviewers see both the diff and the
  updated manifest in the PR.

### Visual regression

- The golden-hash test above is the primary signal (any layout/font/
  copy change flips the hash).
- For the inner raw captures, the existing
  `screenshots/failures/` mechanism in `integration.sh` already covers
  "capture itself broke." No extra coverage added here.

### `flutter analyze`

Per `dart/app/CLAUDE.md`, the composer code must pass
`fvm flutter analyze` with `No issues found!`. The tool lives under
`dart/app/tool/`, which the existing analyzer config already includes.

---

## Key Files Reference

Existing:

- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/integration_test/screenshots_test.dart`
  — drives the app through the 5 screens.
- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/scripts/integration.sh`
  — Patrol runner + awk-based screencap filter.
- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/fastlane/Fastfile`
  — `release`, `beta`, `dev_distribute` lanes; today all skip
  screenshots.
- `/Users/kristian.freed/projects/softmemes/omnilect/dart/app/CLAUDE.md`
  — `fvm flutter analyze` must be clean.
- `/Users/kristian.freed/projects/softmemes/omnilect/web/public/`
  — Astro marketing site; source of truth for brand font (Inter) and
  brand gradient values.

To create:

- `dart/app/tool/screenshots/package.dart` — composer entrypoint.
- `dart/app/tool/screenshots/render_text.dart` — Flutter widget-test
  harness that rasterizes headline/subhead strips.
- `dart/app/screenshots/templates/canvases.yaml` — per-canvas geometry.
- `dart/app/screenshots/templates/copy/en-US.yaml` — copy strings.
- `dart/app/screenshots/templates/frames/{iphone_6_9,ipad_13,android_phone}.png`
  — device frame assets.
- `dart/app/screenshots/packaged/**` — committed packaged PNGs.
- `dart/app/scripts/screenshots.sh` — one-command wrapper.
- `dart/app/test/tool/screenshots_golden_test.dart` — SHA-256 golden
  manifest test.
- `dart/app/fastlane/metadata/{en-US,android/en-US}/…` — Fastlane
  metadata tree (screenshots only; descriptions/keywords empty for now).

---

## Decisions & Assumptions

These were decided without an interactive Q&A round. Push back on any
of them before implementation:

1. **Composer language: Dart.** Rejected alternatives: Fastlane
   `frameit` (awkward for custom copy/gradients), Node/Python (extra
   runtime), Figma (not scriptable in release path).
2. **Device matrix v1: iPhone 6.9" + iPad 13" + Android phone only.**
   Tablets (Android) and landscape variants are deferred.
3. **iOS capture: out of scope for v1.** iOS marketing screenshots in
   v1 are the Android captures composited into iOS device frames.
   Accepting this means iOS store screenshots will show Android-rendered
   pixels inside an iPhone frame — if that's unacceptable to the owner,
   iOS Patrol capture must be elevated to a v1 prerequisite.
4. **Light mode only.** Dark-mode variants are a v2 add-on.
5. **English only.** Localization structure in place; no other locales
   shipped v1.
6. **Packaged PNGs committed to git.** Reviewable in PRs; small file
   count.
7. **Copy is placeholder.** Strings in the table above are draft; owner
   must approve before first `fastlane upload_screenshots` call.
8. **Status bar is synthetic (9:41).** Matches Apple's long-standing
   convention and avoids leaking real emulator state.
9. **MIT red gradient background.** Matches the marketing site + app
   theme. No lifestyle photography / mockup hands / laptop shots in v1.
10. **"Unofficial" wordmark appears on frame 1 only**, small, top-left.
    Balances legal honesty against store-page visual noise.
11. **No CI wiring on PRs.** Composer runs locally + at release. A
    `lint_screenshots` CI job is a cheap follow-up if packaged PNGs
    start drifting.
12. **Tablet Android, landscape video, dark mode, promo video, Play
    feature graphic, App Store description/keywords** — all explicitly
    deferred (see Out of scope).
