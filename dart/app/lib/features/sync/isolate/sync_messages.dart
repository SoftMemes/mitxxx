import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';

// ---------------------------------------------------------------------------
// Main → Isolate: SyncRequest
// ---------------------------------------------------------------------------

/// A user-facing request for the sync isolate to do work.
///
/// Requests are transferred over `SendPort` — every field must be an
/// isolate-safe type (primitives, enums, `DateTime`, `List` of same).
sealed class SyncRequest {
  const SyncRequest({this.trigger = kTriggerManual});
  final String trigger;

  /// Scope id associated with this request — used by the state machine to
  /// decide whether an incoming request is "the same" as one currently
  /// running (debounce) or "different" (cancel-and-replace).
  String get scopeId;

  /// Same-shape check used by the debounce path. Two requests are the same if
  /// their scope ids match.
  bool sameAs(SyncRequest other) => scopeId == other.scopeId;
}

final class FullSyncRequest extends SyncRequest {
  const FullSyncRequest({super.trigger});

  @override
  String get scopeId => ScopeIds.allCourses;
}

final class ListsRefreshRequest extends SyncRequest {
  const ListsRefreshRequest({super.trigger});

  @override
  String get scopeId => ScopeIds.lists;
}

final class CourseSyncRequest extends SyncRequest {
  const CourseSyncRequest(this.courseId, {super.trigger});
  final String courseId;

  @override
  String get scopeId => ScopeIds.course(courseId);
}

final class LectureSyncRequest extends SyncRequest {
  const LectureSyncRequest(
    this.courseId,
    this.sequenceId, {
    super.trigger,
  });
  final String courseId;
  final String sequenceId;

  @override
  String get scopeId => ScopeIds.lecture(sequenceId);
}

/// Refresh the `available_lists` cache — the list-of-lists a user can pick
/// from in Settings → Courses and onboarding. Moved to the sync isolate so
/// its HTTP + cookie-jar IO doesn't block the main UI thread.
final class AvailableListsRefreshRequest extends SyncRequest {
  const AvailableListsRefreshRequest({super.trigger});

  @override
  String get scopeId => ScopeIds.availableLists;
}

// Control messages (main → isolate) — not user requests, so they don't
// carry a scope id and don't interact with the cancel-and-replace path.

/// Main has finished a silent session refresh or user reauth. The isolate
/// should start the latest pending request.
final class SessionRefreshCompleted {
  const SessionRefreshCompleted(this.kind);
  final SessionKind kind;
}

/// Main couldn't refresh (user dismissed reauth, silent bootstrap failed).
/// The isolate should drop the pending request and go idle.
final class SessionRefreshFailed {
  const SessionRefreshFailed(this.kind, [this.reason]);
  final SessionKind kind;
  final String? reason;
}

/// After login completes, the cookie jar on disk has changed — the isolate's
/// in-memory cookie cache needs to be re-read.
final class ReloadCookies {
  const ReloadCookies();
}

/// Cancel any running op and (optionally) wait for in-flight work to drain
/// before acknowledging. Used by sign-out and "delete all app data".
final class StopAll {
  const StopAll({this.drainInFlight = true});
  final bool drainInFlight;
}

/// Ask the isolate to shut down cleanly. Main awaits `IsolateExited`.
final class Shutdown {
  const Shutdown();
}

// ---------------------------------------------------------------------------
// Isolate → Main: SyncEvent
// ---------------------------------------------------------------------------

/// Anything the isolate sends back. Transferable-only fields.
sealed class SyncEvent {
  const SyncEvent();
}

/// One-shot after the isolate has finished initializing Dio, Drift, and
/// cookies, and is ready to accept requests.
final class IsolateReady extends SyncEvent {
  const IsolateReady();
}

/// Emitted after a `Shutdown` is processed. Main can then destroy the port.
final class IsolateExited extends SyncEvent {
  const IsolateExited();
}

final class OpStarted extends SyncEvent {
  const OpStarted(this.scopeId, this.trigger, this.startedAt);
  final String scopeId;
  final String trigger;
  final DateTime startedAt;
}

final class OpCompleted extends SyncEvent {
  const OpCompleted(this.scopeId, this.completedAt, {this.itemsSynced = 0});
  final String scopeId;
  final DateTime completedAt;
  final int itemsSynced;
}

final class OpCancelled extends SyncEvent {
  const OpCancelled(this.scopeId);
  final String scopeId;
}

final class OpErrored extends SyncEvent {
  const OpErrored(this.scopeId, this.message, {this.subScopeId});
  final String scopeId;
  final String? subScopeId;
  final String message;
}

/// Primary UI driver: whenever a scope's state changes, this event goes out.
final class ScopeStateChanged extends SyncEvent {
  const ScopeStateChanged(this.scopeId, this.state);
  final String scopeId;
  final ScopeState state;
}

final class SubtaskProgress extends SyncEvent {
  const SubtaskProgress(this.scopeId, this.completed, this.total);
  final String scopeId;
  final int completed;
  final int total;
}

/// Sync determined these URLs are no longer referenced by the course's
/// canonical structure. VideoDownloadManager should cancel downloads for
/// them and delete local files where orphaned.
final class RemovedVideoUrls extends SyncEvent {
  const RemovedVideoUrls(this.urls, this.courseId);
  final List<String> urls;
  final String courseId;
}

/// Sync needs the LMS / learnApi / mitxonline session refreshed.
final class SessionRefreshRequired extends SyncEvent {
  const SessionRefreshRequired(this.kind);
  final SessionKind kind;
}

/// Isolate wants the main-isolate Firebase Analytics to log an event. The
/// main bridge dispatches based on [eventName].
final class AnalyticsEventForwarded extends SyncEvent {
  const AnalyticsEventForwarded(this.eventName, this.params);
  final String eventName;
  final Map<String, Object?> params;
}

/// A `package:logging` record emitted from the isolate. Main-bridge re-emits
/// it on a `Logger('sync-isolate')` so the existing listeners pick it up.
final class LogRecordForwarded extends SyncEvent {
  const LogRecordForwarded({
    required this.level,
    required this.loggerName,
    required this.message,
    required this.time,
    this.error,
    this.stackTrace,
  });
  final int level;
  final String loggerName;
  final String message;
  final DateTime time;
  final String? error;
  final String? stackTrace;
}

/// The isolate wrote to the DB; main should `ref.invalidate(...)` the listed
/// Riverpod providers so the UI refreshes.
///
/// [family] is a provider family identifier (e.g. `"courseOutline"`), and
/// [arg] is the family argument (e.g. the course id). Non-family providers
/// pass `arg = null`.
final class DbInvalidated extends SyncEvent {
  const DbInvalidated(this.family, [this.arg]);
  final String family;
  final String? arg;
}

/// The isolate built a list of MITx feature-image URLs during a full sync.
/// Main should schedule their download via `courseImageDownloaderProvider`
/// (which requires Riverpod / path_provider on main).
final class PrefetchCourseImages extends SyncEvent {
  const PrefetchCourseImages(this.urls);
  final List<String> urls;
}

/// Post-course-sync: main should revalidate the tracked lecture (progress
/// tracker) because a course's structure may have changed.
final class ValidateTrackedLecture extends SyncEvent {
  const ValidateTrackedLecture(this.courseId);
  final String courseId;
}
