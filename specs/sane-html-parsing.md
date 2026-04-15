# Sane HTML Parsing Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-15

## Description

Building on the work to parse xblocks from MITx, this ensures that all edge cases are covered with the goal to show static regular HTML that has descriptive text, but not to load any interactive elements such as problems to submit — they will not look right or work in the static WebView.

There are a few problems with the existing setup. These have to be resolved by deeply analysing the various options for xblocks. Currently:

- The vertical "Introducing Philosophy: The Three Main Branches..." has a "Loading..." text under the title, then a lot of whitespace.
- "Outline of the Course" has nicely formatted text, but then lots and lots of blank whitespace below it.
- "Outline of the Course: Outline of Part 4" just has a "Loading" text displayed, and a link "Skip to main content" above the header

Use the Python CLI to download and deeply analyse xblocks and revisit the way in which xblocks are parsed/rendered from scratch to keep only safe display-text-only sections. Preserve the existing handling of links (opening in the system browser).

---

*This is a draft specification. Use `/refine-spec sane-html-parsing` to develop it further with structured questioning and technical details.*
