# App Offline Video Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-12

## Description

Building on the offline first mode, this adds optional support for also downloading the videos of a course for a fully offline experience.

- A download button is added in the overview for a course, a sequence, or a vertical — allowing the user to download videos at any of these granularities.
- A progress bar is shown at each level (course, sequence, vertical) indicating how many videos have been downloaded.
- When refreshing the course, downloaded videos are not invalidated — only if the video URLs have changed.
- If URLs have changed, downloading again should only download the new ones (not re-download already-downloaded videos).
- A video that has been downloaded for a given URL is never downloaded again — downloads are deduplicated by URL.

---

*This is a draft specification. Use `/refine-spec app-offline-video` to develop it further with structured questioning and technical details.*
