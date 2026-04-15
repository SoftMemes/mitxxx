# Single-Page Lecture Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-15

## Description

Currently the app provides a page and video player for each "vertical" (part of a lecture), with various hacks for auto-forwarding. This spec strips that down entirely so that instead, all of these snippets are rendered on one page, with the video stitched together as one that plays the lecture end to end.

The non-video content of the lecture is displayed below the video in a list format where only one item is expanded at a time; the user can select a section to expand it.

When the video is started or stopped, it stays in sync with the content so that the relevant section is expanded. This also works when the video moves across a "gap" to the next vertical — the next corresponding section expands and is scrolled into view. This works when the video is scrubbed as well.

There is no longer a next/back button on the lecture as the content is rendered inline in full.

Ideally this should also work for the online case where multiple playlists are combined for the video player and the global position is tracked.

Each section in the list should also have a play button to start playing the video from that section's position.

---

*This is a draft specification. Use `/refine-spec single-page-lecture` to develop it further with structured questioning and technical details.*
