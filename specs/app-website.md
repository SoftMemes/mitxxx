# App Website Specification

> **Version**: 1.0 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-17

## Goals

- Publish a lightweight public marketing site for **MITxxx** at `www.omnilect.app` (apex redirects to www).
- Single landing page explaining what the app is, with App Store / Play Store CTAs.
- Single privacy policy page written in generic terms (no MIT mentions), accurately describing the app's analytics/crash reporting footprint.
- Reorganize the repo's existing `web/` directory into `web/app/` (the current Next.js app) and `web/public/` (this new marketing site).
- Host on Cloudflare Pages via Git integration, main → production, PRs → previews.

## Non-goals

- No blog, support portal, or multi-language support at launch.
- No screenshots at launch — layout reserves space; images added in a later pass.
- No Open Graph / Twitter card metadata at launch.
- No cookie banner (analytics choice avoids that requirement).
- No CMS, auth, forms, or dynamic content. Static files only.

## Tech Stack

**Choice: Astro** (latest stable at implementation time).

Rationale:
- Zero-JS by default — fits a static marketing page where we want fast load and small bundle.
- First-class Markdown/MDX — the privacy policy is written in `.md` and rendered with a shared layout.
- Scoped component styles, no build config to wrangle.
- `npm run build` produces a plain `dist/` tree that Cloudflare Pages serves directly.
- Familiar JSX/HTML-ish syntax; minimal new concepts vs. the Next.js app next door.

Styling: Astro's built-in scoped `<style>` blocks plus a small shared CSS file for tokens (colors, spacing, typography). No Tailwind, no component library — the site is small enough that hand-written CSS is the least-friction choice.

## Directory Layout

**Before:**
```
web/
  package.json         # Next.js app
  src/
  public/
  ...
```

**After:**
```
web/
  app/                 # (moved) existing Next.js app, unchanged contents
    package.json
    src/
    public/
    ...
  public/              # (new) Astro marketing site
    package.json
    astro.config.mjs
    src/
      layouts/
        Base.astro
      pages/
        index.astro
        privacy.astro
      components/
        Hero.astro
        Features.astro
        FAQ.astro
        Footer.astro
      styles/
        tokens.css
      assets/
        app-icon.png        # copied from dart/app/assets/icons/app_icon.png
        favicon.ico
        apple-touch-icon.png
    public/
      robots.txt
      sitemap.xml
```

## Reference Updates

All non-code references to the old `web/` path must be updated to `web/app/`:
- `specs/app-bootstrapping.md` — lines 62 and 174 reference `web/`.
- Repo root `README.md` (if it mentions the web app).
- Repo root `CLAUDE.md` — add a short note about the new `web/` layout.
- `web/CLAUDE.md` / `web/AGENTS.md` — move into `web/app/` along with the rest.

Out of scope: internal code references inside the Next.js app (relative paths) — those don't break from a move.

## Branding

Inferred from the native app:
- **Primary color**: `#A31F34` (MIT red, from `dart/app/lib/core/theme/app_theme.dart`).
- **App icon**: `dart/app/assets/icons/app_icon.png` (copy into `web/public/src/assets/`).
- **App name**: "MITxxx" (display name); package name `omnilect`.

**Palette (tokens.css):**
```
--brand: #A31F34;
--brand-ink: #ffffff;
--bg: #ffffff;
--bg-muted: #f6f6f7;
--ink: #111111;
--ink-muted: #555555;
--border: #e5e5e7;
```

Typography: system font stack (`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif`) — fast, no web-font network cost, looks native on each platform.

## Landing Page Structure (`index.astro`)

Single long-scroll page, mobile-first, max content width ~960px centered.

1. **Hero**
   - App icon (~96px) above `<h1>MITxxx</h1>`.
   - Tagline: *Take your MITx / MIT OpenLearning courses with you — download once, watch anywhere.*
   - Two CTA buttons: **App Store** and **Google Play**.
     - URLs: placeholders `TODO_APP_STORE_URL` and `TODO_PLAY_STORE_URL` in a small `src/config.ts` constants module, filled in before launch.
     - Buttons render as styled `<a>` tags. No JS.

2. **Features** (`Features.astro`)
   Three-card grid on desktop, stacked on mobile:
   - **Offline course access** — Download videos, transcripts, and problems for fully offline playback.
   - **Cast & AirPlay** — Send lectures to a TV with Google Cast or AirPlay.
   - **Clean, fast, native** — Built in Flutter. No ads. Your course content is yours.

3. **Screenshots placeholder**
   Commented-out `<section>` with a TODO note. No visible placeholder images at launch.

4. **FAQ** (`FAQ.astro`)
   Rendered as semantic `<details>`/`<summary>` (no JS). Questions:
   - *Is this an official app?* — No. MITxxx is built by an independent developer and is not affiliated with MIT.
   - *Which courses work?* — Courses on `mitxonline.mit.edu` and `courses.learn.mit.edu` (Open edX). You sign in with your existing account.
   - *Is my login safe?* — Yes. Your credentials are sent directly to the course provider's servers from your device. The app developer never sees them.
   - *Do you track what I study?* — No. The app collects anonymous usage metrics (app opens, crashes, device info) but does not record which courses, lectures, or problems you view.
   - *Where do I report bugs?* — Via GitHub — link in the footer.

5. **Footer** (`Footer.astro`)
   - Small-print disclaimer line:
     *MITxxx is an unofficial, community-built app and is not affiliated with, endorsed by, or sponsored by MIT or MIT OpenLearning.*
   - Links: Privacy Policy (`/privacy`), GitHub repo (`TODO_GITHUB_URL`), Contact (`mailto:contact@omnilect.app`).
   - Copyright: `© 2026 MITxxx`.

## Privacy Policy (`privacy.astro`)

Rendered via a markdown-backed Astro page using the shared `Base` layout. Content (verbatim, no MIT mentions):

```markdown
# Privacy Policy

*Last updated: April 17, 2026*

This privacy policy explains what information the MITxxx mobile app
("the app") collects, how it is used, and your choices.

## What we collect

The app uses **Firebase Analytics** and **Firebase Crashlytics**,
provided by Google, to understand how the app is used and to fix bugs.
The data collected is limited to:

- **Basic usage analytics** — app opens, screen views, session duration,
  and counts of in-app events (for example, "a download started").
- **Device and OS information** — device model, operating system version,
  app version, and locale. No personal identifiers.
- **Crash reports** — stack traces and device context captured when the
  app crashes.
- **Anonymous installation identifier** — a randomly generated ID that
  lets us count unique installs without linking to your identity.

We do **not** collect your name, email, phone number, physical address,
precise location, advertising ID, or contact list. We do not record which
courses, lectures, or problems you view.

## Your course account credentials

The app connects directly to the course provider's servers to sign you
in and fetch your course content. Your username, password, and session
cookies **never pass through any servers run by the app developer**.

## What we do with this information

The analytics and crash data described above are used only to operate
and improve the app — to see which features are used, to identify bugs,
and to prioritize fixes. We do not sell this information, and we do not
share it with advertisers.

## Third-party services

The app's analytics and crash reporting rely on **Firebase** (Google).
Their handling of the data is governed by Google's privacy policy:
<https://policies.google.com/privacy>.

## Children

The app is not directed to children under 13 and does not knowingly
collect data from children.

## Changes to this policy

If we change this policy, the "Last updated" date at the top of this
page will be updated.

## Contact

Questions about this policy can be sent to **contact@omnilect.app**.
```

## Build & Deploy (Cloudflare Pages)

**Project settings:**
- Framework preset: **Astro**.
- Root directory: `web/public`.
- Build command: `npm install && npm run build`.
- Build output directory: `web/public/dist`.
- Node version: `20` (pin via `NODE_VERSION=20` env var on the Pages project).
- Production branch: `main`. Preview: all other branches + PRs.

**Domain:**
- Custom domain: `www.omnilect.app` (canonical).
- Apex `omnilect.app` — add as a secondary domain in Pages and configure a 301 redirect to `https://www.omnilect.app` (Cloudflare Pages redirect rule, or a `_redirects` file with `/* https://www.omnilect.app/:splat 301` on an apex-attached Pages project).
- HTTPS automatic via Cloudflare.

**Analytics:**
- **Cloudflare Web Analytics** enabled on the Pages project. No cookies, no consent banner required.
- Add the Cloudflare beacon snippet to the shared `Base.astro` layout.

## SEO & Static Files

- `<title>` per page (`MITxxx — Offline MITx courses on your phone`, `Privacy Policy — MITxxx`).
- `<meta name="description">` on both pages (~150–160 chars).
- `<link rel="canonical">` pointing to `https://www.omnilect.app/...`.
- `favicon.ico` and `apple-touch-icon.png` (180×180) generated from the app icon.
- `public/robots.txt`:
  ```
  User-agent: *
  Allow: /
  Sitemap: https://www.omnilect.app/sitemap.xml
  ```
- `public/sitemap.xml`: two URLs — `/` and `/privacy` — with `lastmod` set to the build date.
- No Open Graph / Twitter card metadata at launch (explicit non-goal; can be added later).

## Accessibility

- Semantic landmarks: `<header>`, `<main>`, `<footer>`.
- Heading order: single `<h1>` per page, no skipped levels.
- All interactive elements are real `<a>` or `<button>` tags.
- FAQ uses `<details>`/`<summary>` — keyboard-accessible by default.
- Color contrast: brand red on white foreground/text meets WCAG AA.
- All images have meaningful `alt` (or `alt=""` for decorative).
- No JS required for core content to render.

## Testing / Manual QA

- `npm run build` succeeds with zero warnings.
- Open `dist/index.html` and `dist/privacy/index.html` directly in a browser with no server — they render without JS errors.
- Lighthouse on a Cloudflare preview URL: Performance ≥ 95, Accessibility ≥ 95, SEO ≥ 95, Best Practices ≥ 95.
- Visual check at three widths: 360px (small mobile), 768px (tablet), 1280px (desktop).
- Verify footer disclaimer and privacy page link are present on every page.
- Keyboard-tab through the landing page: focus order is logical, focus rings visible.
- Click App Store and Play Store buttons: they either open the real listing (if URLs are populated) or are disabled/`aria-disabled` with a "Coming soon" label (if still placeholders at launch).
- Confirm `www.omnilect.app` and `omnilect.app` both resolve, and the apex 301-redirects to www.
- Confirm the Cloudflare Web Analytics dashboard receives pageviews.

## Implementation Order

1. Create `web/app/` and move all current `web/*` contents into it. Verify the Next.js app still builds from `web/app/` (`npm install && npm run build`).
2. Update references: `specs/app-bootstrapping.md`, root `CLAUDE.md`, root `README.md` if applicable.
3. Scaffold `web/public/` with `npm create astro@latest` (minimal template, TypeScript on, no UI framework).
4. Add shared `Base.astro` layout, `tokens.css`, favicon assets.
5. Build `index.astro` with Hero, Features, FAQ, Footer components. Plug in placeholder store URLs from `src/config.ts`.
6. Author `privacy.astro` with the policy content above.
7. Add `robots.txt`, `sitemap.xml`.
8. Add Cloudflare Web Analytics beacon to `Base.astro`.
9. Push branch → get a Cloudflare Pages preview URL → run QA checklist.
10. Connect `www.omnilect.app` to the Pages project; verify apex redirect.
11. Merge to `main` to promote to production.

## Key Files Reference

Files created:
- `web/public/package.json`, `astro.config.mjs`, `tsconfig.json`
- `web/public/src/layouts/Base.astro`
- `web/public/src/pages/index.astro`
- `web/public/src/pages/privacy.astro`
- `web/public/src/components/{Hero,Features,FAQ,Footer}.astro`
- `web/public/src/styles/tokens.css`
- `web/public/src/config.ts` (store URLs, GitHub URL, contact email)
- `web/public/src/assets/app-icon.png` (copied from `dart/app/assets/icons/app_icon.png`)
- `web/public/src/assets/favicon.ico`, `apple-touch-icon.png`
- `web/public/public/robots.txt`, `sitemap.xml`

Files moved:
- `web/{package.json, next.config.ts, next-env.d.ts, tsconfig.json, eslint.config.mjs, postcss.config.mjs, README.md, AGENTS.md, CLAUDE.md, src/, public/, package-lock.json}` → `web/app/...`

Files updated:
- `specs/app-bootstrapping.md` (references at lines 62 and 174).
- Repo root `CLAUDE.md` (add note about `web/app/` vs `web/public/`).
- Repo root `README.md` (if it references the web app).

## Open TODOs (fill in before/at launch)

- App Store URL.
- Google Play URL.
- GitHub repository URL (footer + FAQ).
- App icon copied to `web/public/src/assets/` (plus derived `favicon.ico`, `apple-touch-icon.png`).
- Cloudflare Pages project created and `www.omnilect.app` + apex domain attached.
- DNS: `contact@omnilect.app` forwarding configured (Cloudflare Email Routing).
