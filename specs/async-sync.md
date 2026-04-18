# Async Sync Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-18

## Description

Currently in the app there are too many edge cases around syncing metadata where things are running when they shouldn't or the UI freezes waiting on something to start/stop. This moves all metadata sync to a background isolate and a single class that knows about the sync operation taking place. This class should ensure that only a single logical metadata sync operation is running at a given point in time, either:

- A full metadata sync of all courses
- Refreshing the "list of lists"
- Refreshing an individual course
- Refreshing an individual lecture
- Or in the future any other operation

This reworks the way the "stale session" detection works. Instead of trying to fix things inside an interceptor and resume, it will detect a 401/403 error on any call, then after the login step up has been completed, cleanly restart the whole previously scheduled logical operations.

The UI interacts with this through "requests", e.g. pulling down to refresh in the home screen requests a full sync — these are always instant and non-blocking operations. Each screen has a loading status tied to the actual sync manager state, so that the loading state of the home screen is shown when syncing the whole set, the loading state on a course is shown when that course is being synced (or scheduled to be synced) for any reason and so on.

Video downloads should be managed via a separate single instance manager class. This runs concurrently with metadata syncs and interacts with it only when lectures/videos are removed from the sync, to ensure that these downloads stop immediately and the respective data is removed. The video download manager is solely responsible for all downloads, deletion, size estimation, etc.

The goals here are to:

1. Never block the UI
2. Always have at most one logical metadata sync operation running
3. Cleanly handle the stale session flow in a way that retries all requests to ensure clean results
4. Downloads running stably and offloaded from the main UI thread

Finally, include a "debugger" tool in the app enabled only for the dev version, accessible from the home screen menu. When opened it shows in technical terms what the metadata sync manager is doing, e.g. what logical operation, how many sub operations (individual downloads) are pending, and so on.

If it would help performance, then the database schema used may be updated to use different serialisation
of blobs (protobufs over json or similar).

---

*This is a draft specification. Use `/refine-spec async-sync` to develop it further with structured questioning and technical details.*
