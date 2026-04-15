# Change to Omnilect Specification

> **Version**: 3.0 (April 2026)
> **Status**: Implemented (Tranche 1)
> **Last Updated**: 2026-04-15

## Description

Rebrand all package identifiers, namespaces, and the Dart package name from `com.softmemes.emajtee` / `emajtee` to `app.omnilect` / `omnilect`. User-facing copy (app name "MITxxx", UI strings) is **not changed** — only technical identifiers.

Introduce two Flutter build flavors (`dev` and `prod`) with distinct package identifiers so both can be installed simultaneously. Set up Fastlane for automated distribution to Firebase App Distribution (dev), TestFlight + Play internal track (beta), and App Store + Play Store production (release).

Scope: `dart/app/` only. Python tools, captures, and repo-level docs are not touched.

---

## Current State

| Item | Current value |
|---|---|
| Flutter package name (`pubspec.yaml`) | `emajtee` |
| Android `applicationId` / `namespace` | `com.softmemes.emajtee` |
| iOS bundle ID | `com.softmemes.emajtee` |
| Apple Development Team | `K83337NAZ8` |
| Firebase project | `mitxxx-f8b17` |
| Firebase Android app ID | `1:478154015759:android:927c5c829f9197bed54f7a` |
| Firebase iOS app ID | `1:478154015759:ios:1d84be350debcdd2d54f7a` |
| Distribution scripts | `scripts/distribute.sh`, `scripts/distribute-android.sh`, `scripts/distribute-ios.sh` |
| Fastlane | Not set up |
| Flutter flavors | Not configured |
| Existing store listings | None (greenfield) |
| Existing user base | Internal testers only — fresh install acceptable |

---

## Target State

### Build Flavors

| Flavor | Package ID | App display name | Distribution target |
|---|---|---|---|
| `dev` | `app.omnilect.dev` | MITxxx (dev) | Firebase App Distribution |
| `prod` | `app.omnilect` | MITxxx | TestFlight / App Store / Play Store |

- Dev flavor gets a visually distinct app icon (badge or color overlay).
- Both flavors use the same Firebase project `mitxxx-f8b17` with separate registered app records.

### Dart Package

`pubspec.yaml` `name:` changes from `emajtee` → `omnilect`. All `import 'package:emajtee/...'` in `lib/` are updated to `package:omnilect`.

---

## Architecture & Design

### Flutter Flavors (dart/app/)

Flutter flavors are implemented via:
- **Android**: `productFlavors` blocks in `build.gradle.kts` with `applicationId` per flavor
- **iOS**: Xcode schemes + build configurations (`Debug-dev`, `Release-dev`, `Debug-prod`, `Release-prod`) with `PRODUCT_BUNDLE_IDENTIFIER` per configuration
- **Dart**: `main_dev.dart` and `main_prod.dart` entry points; a `FlavorConfig` class in `lib/flavor_config.dart` that exposes the active flavor

### Firebase Config Per Flavor

Use `flutterfire configure` to generate flavor-specific Firebase options:
- `lib/firebase_options_dev.dart` — registered as `app.omnilect.dev` under `mitxxx-f8b17`
- `lib/firebase_options_prod.dart` — registered as `app.omnilect` under `mitxxx-f8b17`

Both `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) are regenerated with multiple app entries and selected at build time.

### Fastlane Setup

Fastlane lives at `dart/app/fastlane/`. Three lanes:

| Lane | Platforms | What it does |
|---|---|---|
| `dev_distribute` | iOS + Android | Builds `dev` flavor → uploads to Firebase App Distribution (`internal` group) |
| `beta` | iOS + Android | Builds `prod` flavor → TestFlight internal + Play Store internal track |
| `release` | iOS + Android | Builds `prod` flavor → App Store submission + Play Store production |

iOS code signing uses **Fastlane match** (git strategy). A private repo (e.g., `github.com/kristian-freed/match-certs`) stores encrypted certs and provisioning profiles for both bundle IDs.

Android signing continues to use the existing keystore in `dart/app/android/app/keys/` via `key.properties`.

---

## Implementation Plan

### Phase 1 — Dart Package Rename

1. In `dart/app/pubspec.yaml`: change `name: emajtee` → `name: omnilect`
2. Bulk-replace all `import 'package:emajtee/` → `import 'package:omnilect/` across `dart/app/lib/`
3. Update any references in `dart/app/test/` if present

### Phase 2 — Android Flavor Setup

1. Edit `dart/app/android/app/build.gradle.kts`:
   - Change `namespace` to `app.omnilect`
   - Replace single `applicationId "com.softmemes.emajtee"` with `productFlavors`:
     ```
     dev   → applicationId "app.omnilect.dev"
     prod  → applicationId "app.omnilect"
     ```
2. Update `dart/app/android/app/src/main/AndroidManifest.xml` if package is hardcoded
3. Rename/create flavor source sets if needed (`src/dev/`, `src/prod/`)

### Phase 3 — iOS Flavor Setup

1. In Xcode project (`dart/app/ios/Runner.xcodeproj/project.pbxproj`):
   - Duplicate `Debug` and `Release` configurations → `Debug-dev`, `Release-dev`, `Debug-prod`, `Release-prod`
   - Set `PRODUCT_BUNDLE_IDENTIFIER` per configuration:
     - `*-dev` → `app.omnilect.dev`
     - `*-prod` → `app.omnilect`
2. Create two Xcode schemes: `Runner-dev` and `Runner-prod`, each using their build configurations
3. Update `dart/app/ios/Runner/Info.plist` to use `$(PRODUCT_BUNDLE_IDENTIFIER)`
4. Update `dart/app/ios/RunnerTests/RunnerTests.xctest` bundle ID to `app.omnilect.RunnerTests` / `app.omnilect.dev.RunnerTests`

### Phase 4 — Flavor Entry Points & Dart Config

1. Create `dart/app/lib/flavor_config.dart`:
   ```dart
   enum Flavor { dev, prod }
   class FlavorConfig {
     static Flavor? _flavor;
     static void set(Flavor f) => _flavor = f;
     static Flavor get flavor => _flavor!;
     static bool get isDev => _flavor == Flavor.dev;
   }
   ```
2. Create `dart/app/lib/main_dev.dart` (sets `FlavorConfig.set(Flavor.dev)`, calls `main()`)
3. Create `dart/app/lib/main_prod.dart` (sets `FlavorConfig.set(Flavor.prod)`, calls `main()`)
4. Update `dart/app/android/app/build.gradle.kts` to point each flavor to its entry point

### Phase 5 — Firebase App Registration

**Automated (CLI):**
```bash
# Register new Android apps
firebase apps:create ANDROID app.omnilect --project mitxxx-f8b17
firebase apps:create ANDROID app.omnilect.dev --project mitxxx-f8b17

# Register new iOS apps
firebase apps:create IOS app.omnilect --project mitxxx-f8b17
firebase apps:create IOS app.omnilect.dev --project mitxxx-f8b17

# Download updated config files
firebase apps:sdkconfig ANDROID <new-prod-app-id> -o dart/app/android/app/google-services.json
# (google-services.json supports multiple app entries — include all 4 app IDs)
```

Then run `flutterfire configure` to generate `lib/firebase_options_dev.dart` and `lib/firebase_options_prod.dart`.

**Manual step:** Remove old `com.softmemes.emajtee` app records from the Firebase console after verifying new records work.

### Phase 6 — Dev App Icon

1. Create a dev-variant icon set with a badge (e.g., orange banner reading "DEV")
2. Place in `dart/app/assets/icons/dev/`
3. Use `flutter_launcher_icons` with flavor support in `pubspec.yaml` to generate flavor-specific icon sets

### Phase 7 — Fastlane Setup

**Initial setup:**
```bash
cd dart/app
gem install fastlane
fastlane init   # creates fastlane/Appfile, fastlane/Fastfile
```

**Appfile:**
```ruby
app_identifier ["app.omnilect", "app.omnilect.dev"]
apple_id "kristian@slingshotai.com"
itc_team_id "..."   # fill in
team_id "K83337NAZ8"
```

**match setup (manual step required first):**
- Create a private GitHub repo for certs (e.g., `kristian-freed/match-certs`)
- Run `fastlane match init` → point to that repo
- Run `fastlane match development --app_identifier app.omnilect,app.omnilect.dev`
- Run `fastlane match appstore --app_identifier app.omnilect`
- Run `fastlane match adhoc --app_identifier app.omnilect.dev`

**Fastfile lanes** (see Key Files section for full content):
- `dev_distribute`: `flutter build --flavor dev`, Firebase App Distribution upload
- `beta`: `flutter build --flavor prod`, TestFlight + Play internal
- `release`: `flutter build --flavor prod`, App Store + Play production

### Phase 8 — Store Registration

**App Store Connect (manual — no CLI to create new app listing):**
1. Generate App Store Connect API key: App Store Connect → Users & Access → Integrations → API Keys → Generate
2. Save `.p8`, note Issuer ID and Key ID
3. Create new app in App Store Connect with bundle ID `app.omnilect`
4. Add to `fastlane/Appfile` and store `.p8` securely (not committed)

**Google Play Console (manual):**
1. Create new app in Play Console for `app.omnilect`
2. Create service account: Google Cloud Console → IAM → Service Accounts → create → grant Play Developer API access
3. Download service account JSON → reference in Fastfile as `json_key_file`

**Firebase App Distribution:**
- Automated via `firebase appdistribution:distribute` in Fastlane lane
- No manual registration needed beyond Phase 5

### Phase 9 — Script Cleanup

Replace `scripts/distribute.sh`, `scripts/distribute-android.sh`, `scripts/distribute-ios.sh` with thin wrappers that call `fastlane dev_distribute` / `fastlane beta` / `fastlane release`, or delete them entirely.

---

## Key Files to Modify

| File | Change |
|---|---|
| `dart/app/pubspec.yaml` | Rename `name: emajtee` → `omnilect`; add flavor icon config |
| `dart/app/android/app/build.gradle.kts` | Add `productFlavors`, update `applicationId`, `namespace` |
| `dart/app/android/app/src/main/AndroidManifest.xml` | Remove hardcoded package if present |
| `dart/app/ios/Runner.xcodeproj/project.pbxproj` | Add build configs, update bundle IDs per config |
| `dart/app/ios/Runner/Info.plist` | Use `$(PRODUCT_BUNDLE_IDENTIFIER)` variable |
| `dart/app/android/app/google-services.json` | Regenerated with new app IDs |
| `dart/app/ios/Runner/GoogleService-Info.plist` | Regenerated for prod flavor |
| `dart/app/ios/Runner/GoogleService-Info-dev.plist` | New file for dev flavor |
| `dart/app/lib/**/*.dart` | Bulk replace `package:emajtee` → `package:omnilect` |
| `dart/app/lib/main_dev.dart` | New entry point for dev flavor |
| `dart/app/lib/main_prod.dart` | New entry point for prod flavor |
| `dart/app/lib/flavor_config.dart` | New flavor config class |
| `dart/app/lib/firebase_options_dev.dart` | New — generated by flutterfire |
| `dart/app/lib/firebase_options_prod.dart` | New — generated by flutterfire |
| `dart/app/fastlane/Fastfile` | New — lanes: dev_distribute, beta, release |
| `dart/app/fastlane/Appfile` | New — app identifiers, team IDs |
| `scripts/distribute*.sh` | Replace or delete |

---

## Manual Steps Required (Cannot Be Automated)

1. **Create App Store Connect API key** — App Store Connect UI → Users & Access → Integrations → API Keys
2. **Create new App Store Connect app listing** — no CLI; must be done in App Store Connect UI
3. **Create Google Play app listing** — must be done in Play Console UI
4. **Create Google Play service account** — Google Cloud Console UI, then grant Play API access
5. **Create match certs repo** — create a private GitHub repo, then run `fastlane match init`
6. **Run `fastlane match`** to populate certs for the first time

---

## Verification

```bash
# Build dev flavor (Android)
flutter build apk --flavor dev --target lib/main_dev.dart

# Build prod flavor (iOS)
flutter build ios --flavor prod --target lib/main_prod.dart --no-codesign

# Distribute dev build to Firebase App Distribution
cd dart/app && fastlane dev_distribute

# Verify both apps installable simultaneously on device
# (app.omnilect.dev and app.omnilect should both appear on home screen)
```

Check:
- [ ] Both flavors build without errors
- [ ] Both apps install simultaneously on a test device
- [ ] Dev app shows "MITxxx (dev)" display name and distinct icon
- [ ] Prod app shows "MITxxx" display name and normal icon
- [ ] Firebase Crashlytics and Analytics receive events from both apps (verify in Firebase console under separate app entries)
- [ ] `fastlane dev_distribute` uploads to Firebase App Distribution without errors

---

*Specification refined 2026-04-15. Use `/implement-spec change-to-omnilect` to begin implementation.*
