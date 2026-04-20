import 'package:flutter/foundation.dart' show immutable;

/// Status of a single sync scope (a course, a lecture, the full-sync
/// top-level, etc.).
///
/// `scheduled` is the state a scope is in when it's part of the current
/// logical op but its sub-tasks haven't started yet. UI uses it to render a
/// faint shimmer; `syncing` gets the stronger indicator.
enum ScopeStatus { idle, scheduled, syncing, error }

/// Mirrored, main-isolate state for a single sync scope — **ephemeral only**.
///
/// Holds what's happening *right now* in the sync isolate: which op is
/// touching this scope, and how much of its sub-work is done. Persisted
/// "last synced" / "last error" metadata lives in the DB
/// (`cached_course_sync`, `cached_lecture_sync`) and is surfaced to the UI
/// via `courseSyncRecordProvider` / `lectureSyncRecordProvider`. UI-facing
/// widgets read the combined [ScopeDisplay] from
/// `courseScopeStateProvider` / `lectureScopeStateProvider`.
///
/// Keyed in the sync manager state map by a scope id string — see [ScopeIds]
/// for the conventions (`all-courses`, `lists`, `course:<id>`,
/// `lecture:<seqId>`).
@immutable
class ScopeState {
  const ScopeState({
    this.status = ScopeStatus.idle,
    this.completed = 0,
    this.total = 0,
  });

  final ScopeStatus status;

  /// Sub-task counters — drive the fractional-fill progress bar on course
  /// and lecture rows, and the dev debugger.
  final int completed;
  final int total;

  ScopeState copyWith({
    ScopeStatus? status,
    int? completed,
    int? total,
  }) {
    return ScopeState(
      status: status ?? this.status,
      completed: completed ?? this.completed,
      total: total ?? this.total,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScopeState &&
        other.status == status &&
        other.completed == completed &&
        other.total == total;
  }

  @override
  int get hashCode => Object.hash(status, completed, total);

  @override
  String toString() {
    final parts = <String>['status=$status'];
    if (total > 0) parts.add('progress=$completed/$total');
    return 'ScopeState(${parts.join(', ')})';
  }
}

/// Composite view of a scope for UI consumers. Combines the ephemeral
/// in-memory [ScopeState] (status + progress) with the persisted DB record
/// (last-synced timestamp + last error message) so widgets can render
/// "Synced X ago" even after a force-kill / cold restart, and so a failing
/// re-sync doesn't wipe the prior successful timestamp from the UI.
@immutable
class ScopeDisplay {
  const ScopeDisplay({
    this.status = ScopeStatus.idle,
    this.completed = 0,
    this.total = 0,
    this.lastSyncedAt,
    this.errorMessage,
  });

  final ScopeStatus status;
  final int completed;
  final int total;
  final DateTime? lastSyncedAt;
  final String? errorMessage;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScopeDisplay &&
        other.status == status &&
        other.completed == completed &&
        other.total == total &&
        other.lastSyncedAt == lastSyncedAt &&
        other.errorMessage == errorMessage;
  }

  @override
  int get hashCode => Object.hash(
        status,
        completed,
        total,
        lastSyncedAt,
        errorMessage,
      );

  @override
  String toString() {
    final parts = <String>['status=$status'];
    if (total > 0) parts.add('progress=$completed/$total');
    if (lastSyncedAt != null) parts.add('lastSyncedAt=$lastSyncedAt');
    if (errorMessage != null) parts.add('error="$errorMessage"');
    return 'ScopeDisplay(${parts.join(', ')})';
  }
}

/// Scope id builder. Keep the formats stable — UI providers select by string.
abstract final class ScopeIds {
  static const String allCourses = 'all-courses';
  static const String lists = 'lists';
  static const String availableLists = 'available-lists';
  static String course(String courseId) => 'course:$courseId';
  static String lecture(String sequenceId) => 'lecture:$sequenceId';
}
