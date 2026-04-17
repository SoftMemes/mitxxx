# Opencourseware Support Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-17

## Description

Building on course-shortlist-sync, I want to fully support OpenCourseWare courses in the app, presented as much as possible in the same way as the existing courses.

This looks different: instead of xblocks, there's a list of videos for the course. I want to model one lecture as one video and access only the video content of the course. There are no individual xblocks inside a lecture, so just use the video player.

Also join this up with the lecture notes when available — make the lecture note resources available as generated content in the lecture details page. These are downloads; just present them as links — do not download their content. Match these by name to the relevant lecture.

The video content and metadata should be synced in the same way as the existing MITx courses.

---

*This is a draft specification. Use `/refine-spec opencourseware-support` to develop it further with structured questioning and technical details.*
