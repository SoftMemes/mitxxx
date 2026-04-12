# App True Offline Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-12

## Description

The app currently gets courses on demand with offline caching but read-through — it's online with offline support. This should be changed into a true offline-first experience.

**Authentication & Course Index**

- App first requests a login
- After login, loads the current courses available as an index
- There should be a button on the home screen to refresh the list of courses available

**Refresh / Metadata Sync**

- When refreshing, it should refresh the metadata (all sequences, xblocks, etc.)
- There should be a spinner for each course as it's being updated
- In this default mode, video content is not downloaded (to be added later) — but the metadata is cached

**Lecture Page UI Rework**

- A lecture is shown on one page as now, but instead of listing the entire content all in one page, there are buttons to navigate back/forward between the pages (blocks/verticals)

**Video Playback Behavior**

- When playing a video in full-screen mode, when the video completes and runs to the end, it will auto-forward to the next video
- If the video is closed (exited before completion), it will show the block for the video that was playing — not where it was starting

---

*This is a draft specification. Use `/refine-spec app-true-offline` to develop it further with structured questioning and technical details.*
