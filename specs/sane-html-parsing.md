# Sane HTML Parsing Specification

> **Version**: 1.1 (April 2026)
> **Status**: Ready for Implementation
> **Last Updated**: 2026-04-15

## Description

The MITx xblock HTML rendered by the LMS is a full page response containing multiple
xblock types per vertical. Only `html`-type xblocks contain displayable static text.
All other types (`problem`, `discussion`, `video`) require LMS JavaScript to function
and must be excluded entirely. The current sanitizer has a fallback path that returns
the raw LMS page when no `html` block is found, causing "Loading…" text and
"Skip to main content" noise. This spec replaces the sanitizer and WebView wrapper
with a correct, fully audited implementation.

---

## Audit Findings (course-v1:MITxT+24.09x+1T2025, 15/61 sequences sampled)

99 verticals fetched via `python-tools/mitx-client/cli.py xblock --show-html`.

**Block types found:**

| `data-block-type` | Verticals containing it | Action |
|---|---|---|
| `vertical` | 99 (all) | Container — ignored |
| `video` | 80 | Strip (already handled by `stripVideoBlocks`) |
| `discussion` | 80 | Exclude entirely |
| `problem` | 75 | Exclude entirely |
| `html` | 68 | **Keep** — only type with static displayable content |

No other xblock types present in this course. The allowlist (`html` only) is
sufficient for this dataset. The implementation should use `data-block-type="html"`
as the selector (not CSS class name) so it is robust to class-name changes.

**Concrete bug causes identified:**

- *"Loading…" / "Skip to main content"* — verticals with no `html` block (e.g.
  "Three Main Branches of Philosophy", "Outline of Part 4") trigger the fallback
  path in the current `sanitizeXBlockHtml`, which returns the full stripped LMS
  page including `problem` blocks that render "Loading…" via `xmodule_ProblemBlock`.
- *Trailing whitespace* — `HtmlBlock` initialises at 400px height; the WebView
  takes up to 1 second to report the real `scrollHeight`, leaving a visible blank
  band until the resize fires.

---

## Architecture & Design

### xblock sanitizer (`sanitizeXBlockHtml`)

**Replace** the current implementation with:

1. Parse the full LMS HTML page.
2. Select all elements matching `[data-block-type="html"]` — these are the only
   safe static-content blocks.
3. For each matched element, collect its child nodes, skipping:
   - `<script>` elements (Open edX injects `type="json/xblock-args"` scripts as
     direct siblings to the content).
   - Whitespace-only text nodes.
4. If no content nodes are found (vertical has no `html` block) → **return empty
   string**. Do NOT fall back to the full page. The tile's `_ExpandedContent`
   widget already handles `html.isEmpty` with a "No additional content" message.
5. Build a clean minimal document: `<!doctype html><html><head></head><body>…</body></html>`
   with only the collected nodes.
6. Strip empty `<p>` elements (no text, no element children).
7. Return `cleanDoc.documentElement!.outerHtml`.

**Remove** the existing fallback path (`if (contentNodes.isEmpty) { return
stripVideoBlocks(html)… }`).

`stripVideoBlocks` and `extractVideoMetadata` are unchanged and remain in the file.

### WebView height (`HtmlBlock`)

**Replace** the fixed `_height = 400` initial value with `_height = 0`. The
WebView is invisible until the first `FlutterHeight` callback fires (within
~300ms on device). There is no spinner — content pops in when sized. This
eliminates the blank gap.

The existing `FlutterHeight` JS handler logic is unchanged:
```dart
if (h != null && h > 0 && mounted && (h - _height).abs() > 4) {
  setState(() => _height = h + 24);
}
```

### MathJax

MathJax 2.7.5 with config `TeX-MML-AM_SVG` (matching what the LMS references)
must be bundled in the app and injected into each WebView.

**Steps:**
1. Download `MathJax.js?config=TeX-MML-AM_SVG` combined+minified build from the
   MathJax 2.7.5 release (npmjs: `mathjax@2.7.5`). Save as
   `dart/app/assets/js/mathjax.min.js`.
2. Track with Git LFS: add `dart/app/assets/js/*.js filter=lfs diff=lfs merge=lfs -text`
   to `.gitattributes` at the repo root.
3. Register the asset in `dart/app/pubspec.yaml` under `flutter.assets`.
4. In `HtmlBlock._wrapHtml`, read the asset as a string at widget creation time
   (or load once via `rootBundle.loadString`) and inject it inline as a
   `<script>` tag inside `<head>`, **before** the `FlutterHeight` script.
   Inline injection avoids the `about:blank` origin blocking `file://` asset
   loads in `WKWebView`/`WebView`.

MathJax config to inject before the script (sets up the same delimiters the LMS
uses):
```html
<script type="text/x-mathjax-config">
  MathJax.Hub.Config({
    messageStyle: "none",
    tex2jax: {
      inlineMath: [["\\(","\\)"], ["[mathjaxinline]","[/mathjaxinline]"]],
      displayMath: [["\\[","\\]"], ["[mathjax]","[/mathjax]"]]
    }
  });
</script>
```

### Link handling (preserve as-is)

No changes to the existing link-open behaviour:
- JS click interceptor in `_wrapHtml` calls `FlutterOpenUrl` handler.
- `_resolveLinkUri` prefixes relative paths with `https://courses.learn.mit.edu`.
- `url_launcher` opens the resolved URL in the system browser.
- `shouldOverrideUrlLoading` as fallback.

---

## xblock Type Handling Summary

| Block type | Detected by | Action |
|---|---|---|
| `html` | `[data-block-type="html"]` | Extract child content nodes |
| `video` | existing `stripVideoBlocks` (class-based) | Already stripped before sanitizer runs |
| `problem` | not `html` → not selected | Silently excluded |
| `discussion` | not `html` → not selected | Silently excluded |
| `vertical` | container | Never selected |
| any future type | not `html` → not selected | Silently excluded (allowlist is safe by default) |

---

## Fallback Behaviour

| Scenario | Behaviour |
|---|---|
| Vertical has one or more `html` blocks | Show extracted content |
| Vertical has no `html` block | `sanitizeXBlockHtml` returns `""` → tile shows "No additional content for this section." |
| HTML block has content but no text (e.g. images only) | Shown as-is |
| MathJax in html block | Rendered by bundled MathJax |

---

## Key Files

| File | Change |
|---|---|
| `dart/app/lib/features/courses/utils/xblock_parser.dart` | Rewrite `sanitizeXBlockHtml`: allowlist `[data-block-type="html"]`, remove fallback |
| `dart/app/lib/features/courses/widgets/html_block.dart` | `_height = 0` initial; inject bundled MathJax inline |
| `dart/app/assets/js/mathjax.min.js` | New file — MathJax 2.7.5 TeX-MML-AM_SVG build (Git LFS) |
| `dart/app/pubspec.yaml` | Register `assets/js/mathjax.min.js` |
| `.gitattributes` (repo root) | `dart/app/assets/js/*.js filter=lfs diff=lfs merge=lfs -text` |

---

## Testing Strategy

1. `cd dart/app && /home/freed/fvm/bin/fvm flutter analyze` — no new errors.
2. Spot-check using `python-tools/mitx-client/cli.py xblock <id> --show-html` then
   run `sanitizeXBlockHtml` on the output and assert:
   - Returns `""` for `[video+problem+discussion]` verticals (no html block).
   - Returns clean `<p>` / `<ul>` content for `[html+...]` verticals.
   - Contains no `Loading` text, no `Skip to main content`, no `<script>` tags.
3. Manual QA on device:
   - Open a lecture → expand "Three Main Branches of Philosophy" → shows
     "No additional content for this section." (not "Loading…").
   - Open "What is Philosophy?" → shows static text + no trailing blank gap.
   - Open "Outline of the Course" → shows text, resizes to content height with
     no large blank space below.
   - Tap a link → system browser opens with full resolved URL.
   - Vertical with LaTeX → equations render via bundled MathJax.
