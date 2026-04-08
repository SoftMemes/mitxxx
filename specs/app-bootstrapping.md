# App Bootstrapping Specification

> **Version**: 1.1 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-08

## Description

Set up the Flutter app in the `app/` directory as the foundation for an unofficial MITx offline course app. The app allows users to sync enrolled MITx courses — including all content and video — for offline consumption on Android and iOS.

---

## Platform Targets

| Platform | Status |
|---|---|
| Android | Full setup |
| Web | Full setup |
| iOS | Directory included; Xcode-specific config deferred (Linux environment limitation) |

---

## App Identity

| Field | Value |
|---|---|
| Package name / App ID | `com.softmemes.emajtee` |
| Display name | `MITxxx` |
| Minimum Android SDK | API 21 (Android 5.0) |
| Flutter version | Pinned via FVM (Flutter Version Manager) — add `.fvm/fvm_config.json` |

---

## Architecture & Design

### Folder Structure (Feature-based)

```
app/
  lib/
    features/
      auth/
        providers/
        screens/
        models/
      courses/
        providers/
        screens/
        models/
      player/
        providers/
        screens/
        models/
    core/
      network/       # Dio client, interceptors, cookie jar
      storage/       # Drift database setup
      router/        # go_router configuration
    main.dart
  test/
  android/
  ios/               # stub only
  web/
```

### State Management
- **Riverpod** — compile-safe, async-friendly, used for all providers across features

### Navigation
- **go_router** — declarative routing, web URL support, deep links

### Local Storage
- **Drift (SQLite)** — type-safe, reactive. Schema will cover: courses, sections, blocks, video metadata, sync state

### Network Layer
- **Dio** with:
  - `dio_cookie_manager` — cookie jar for managing 3-stage OAuth2 session cookies (`session`, `mitxonline-production-edx-lms-sessionid`, JWT cookies)
  - Interceptors for auth header injection and error handling

---

## Dependencies

### Runtime
| Package | Purpose |
|---|---|
| `flutter_riverpod` / `riverpod_annotation` | State management |
| `go_router` | Navigation |
| `drift` + `sqlite3_flutter_libs` | Local SQLite database |
| `dio` | HTTP client |
| `dio_cookie_manager` + `cookie_jar` | Cookie management for OAuth2 |
| `flutter_secure_storage` | Store auth tokens/session cookies securely |
| `freezed_annotation` + `json_annotation` | Immutable models + JSON serialization |
| `connectivity_plus` | Online/offline detection for sync logic |

### Dev/Build
| Package | Purpose |
|---|---|
| `build_runner` | Code generation trigger |
| `freezed` | Generates immutable data classes |
| `json_serializable` | Generates `fromJson`/`toJson` |
| `riverpod_generator` | Generates Riverpod providers |
| `drift_dev` | Generates Drift database code |
| `flutter_launcher_icons` | App icon generation |
| `flutter_native_splash` | Splash screen generation |
| `very_good_analysis` | Strict lint ruleset |
| `fvm` | Flutter version pinning |

---

## Initial Screens

All screens are scaffolds — navigation wired up, content is placeholder.

| Screen | Route | Notes |
|---|---|---|
| Splash | `/` (initial) | Shows while checking auth state and initializing DB |
| Login | `/login` | Placeholder login form; full auth in separate spec |
| Home | `/home` | Enrolled courses list (empty state for bootstrap) |
| Settings | `/settings` | Accessible from home via nav |

Router logic: splash checks auth state → redirects to `/login` or `/home`.

---

## Configuration

- **Single environment** for now (no dev/prod split)
- Base URLs hardcoded in `core/network/`:
  - `https://mitxonline.mit.edu`
  - `https://courses.learn.mit.edu`

---

## Assets

- App icon: placeholder generated via `flutter_launcher_icons` (simple colored square with "M" or similar)
- Splash screen: placeholder via `flutter_native_splash` (solid background color)
- Replace with real assets in a later pass

---

## Code Style

- `very_good_analysis` lint ruleset via `analysis_options.yaml`

---

## CI/CD

Skipped for bootstrap. To be added in a later spec.

---

## Key Files to Create

```
app/
  pubspec.yaml
  analysis_options.yaml
  .fvm/fvm_config.json
  lib/
    main.dart
    core/
      router/app_router.dart
      network/dio_client.dart
      storage/app_database.dart (Drift)
    features/
      auth/screens/login_screen.dart
      courses/screens/home_screen.dart
      (settings)/screens/settings_screen.dart
  android/
    app/build.gradle         # package name, minSdk 21
    app/src/main/AndroidManifest.xml
  web/
    index.html               # Flutter web entry
  ios/                       # stub directory, minimal config
  assets/
    icons/                   # placeholder launcher icons
    splash/                  # placeholder splash assets
```
