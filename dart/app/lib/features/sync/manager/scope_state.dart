import 'package:flutter/foundation.dart' show immutable;

/// Status of a single sync scope (a course, a lecture, the full-sync
/// top-level, etc.).
///
/// `scheduled` is the new state introduced by the async-sync refactor — a
/// scope is part of the current logical op but its sub-tasks haven't started
/// yet. UI uses it to render a faint shimmer; `syncing` gets the stronger
/// indicator.
enum ScopeStatus { idle, scheduled, syncing, error }

/// Mirrored, main-isolate state for a single sync scope.
///
/// Keyed in the sync manager state map by a scope id string — see [ScopeIds]
/// for the conventions (`all-courses`, `lists`, `course:<id>`,
/// `lecture:<seqId>`).
@immutable
class ScopeState {
  const ScopeState({
    this.status = ScopeStatus.idle,
    this.lastSyncedAt,
    this.errorMessage,
    this.completed = 0,
    this.total = 0,
  });

  final ScopeStatus status;
  final DateTime? lastSyncedAt;
  final String? errorMessage;

  /// Sub-task counters — used by the dev debugger. UI surfaces only show the
  /// boolean status per spec.
  final int completed;
  final int total;

  ScopeState copyWith({
    ScopeStatus? status,
    DateTime? lastSyncedAt,
    String? errorMessage,
    int? completed,
    int? total,
  }) {
    return ScopeState(
      status: status ?? this.status,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      completed: completed ?? this.completed,
      total: total ?? this.total,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ScopeState &&
        other.status == status &&
        other.lastSyncedAt == lastSyncedAt &&
        other.errorMessage == errorMessage &&
        other.completed == completed &&
        other.total == total;
  }

  @override
  int get hashCode => Object.hash(
        status,
        lastSyncedAt,
        errorMessage,
        completed,
        total,
      );

  @override
  String toString() {
    final parts = <String>['status=$status'];
    if (lastSyncedAt != null) parts.add('lastSyncedAt=$lastSyncedAt');
    if (errorMessage != null) parts.add('error="$errorMessage"');
    if (total > 0) parts.add('progress=$completed/$total');
    return 'ScopeState(${parts.join(', ')})';
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
