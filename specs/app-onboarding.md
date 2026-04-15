# App Onboarding Specification

> **Version**: 1.1 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-15

## Description

A full-screen onboarding modal shown to every user once (including existing users on the first launch after the feature ships). It appears **before the login screen** and explains what the app is, what it is not, and how user data is handled. The user must actively acknowledge it before proceeding. Once acknowledged, it never appears again.

A read-only version of the same content is accessible from the existing (currently stub) Settings → About screen.

---

## UX & Presentation

### Layout
- **Full-screen modal** — covers the entire screen; nothing is visible or accessible behind it.
- **No app bar / no back button** — the Android back gesture is suppressed; there is no navigation chrome. The only way forward is the acknowledge button.
- **Top section**: App icon (launcher icon asset) + app name "MITxxx".
- **Body section**: Scrollable content with the four disclosure points (see Copy below).
- **Bottom section** (sticky / outside scroll): Checkbox row + "I understand" button.

### Dismissal
- A **checkbox** must be ticked before the "I understand" button becomes active.
- Tapping "I understand" with the checkbox checked: sets the seen flag, navigates to the login screen, never shows the modal again.
- Back gesture / button: **no-op** (PopScope canPop: false).

### About screen (re-read path)
- Settings → About navigates to a read-only screen showing the same four disclosure points without the checkbox/button.
- This screen has a normal app bar with a back button.

---

## Copy

**Heading**: About MITxxx

**Bullet points** (exact wording, light formatting allowed):

1. **Not affiliated with MIT** — MITxxx is an independent app and is not affiliated with, endorsed by, or officially connected to MIT or MIT OpenLearning.

2. **Offline access to your enrolled courses** — This app lets you read and watch content from MIT Learn courses you are already enrolled in, including downloading video content for offline use.

3. **Manage your courses on MIT Learn** — Enrolment, assignments, submissions, grading, and all other course management must be done directly on the [MIT Learn platform](https://mitxonline.mit.edu).

4. **Your data stays with MIT** — Your login credentials and course data are only shared with MIT's servers. They are never sent to any third-party services or stored outside of MIT's infrastructure and your own device.

**Checkbox label**: I have read and understood the above.

**Button label**: I understand

---

## Architecture & Design

### Routing / Trigger

- The onboarding check happens at **app startup**, before the login screen is pushed.
- In `go_router`'s redirect logic (or in the root widget's `build`): read the SharedPreferences flag `onboarding_acknowledged` (bool, default false).
  - If `false` → push `/onboarding` as the initial route.
  - If `true` → proceed to `/login` (existing flow).
- The `/onboarding` route is not accessible via deep-link or normal navigation once dismissed.

### Persistence

- **Package**: `shared_preferences` (already likely in pubspec; add if not).
- **Key**: `onboarding_acknowledged` (bool).
- Written to `true` when the user taps "I understand". Never reset (survives logout, account switches, DB wipes).
- Existing users: flag does not exist on their device → they see onboarding on first launch after update, same as new installs.

### About screen

- The existing Settings menu item (currently a stub) is wired to a new `/settings/about` route.
- Renders the same four disclosure points as static text — no checkbox, no button, normal scaffold with back navigation.

---

## Key Files to Create / Modify

| File | Change |
|---|---|
| `lib/features/onboarding/screens/onboarding_screen.dart` | **New** — full-screen modal widget |
| `lib/features/settings/screens/about_screen.dart` | **New** — read-only disclosure screen |
| `lib/core/router/app_router.dart` (or equivalent) | Add `/onboarding` and `/settings/about` routes; add redirect logic |
| `lib/features/settings/screens/settings_screen.dart` (or equivalent) | Wire stub "About" item to `/settings/about` |
| `pubspec.yaml` | Add `shared_preferences` if not already present |

---

## Behaviour Summary

| Scenario | Behaviour |
|---|---|
| Brand-new install | Onboarding shown before login |
| Existing install, first launch after update | Onboarding shown before login |
| User has acknowledged | Goes straight to login, onboarding never shown again |
| User presses back on onboarding | Nothing happens |
| User opens Settings → About | Read-only disclosure screen, normal back navigation |
| User logs out | Onboarding does NOT reappear (flag is persisted independently of auth) |
| App data wiped / reinstall | SharedPreferences cleared → onboarding shown again on next launch |
