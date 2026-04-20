import 'package:flutter/foundation.dart' show immutable;
import 'package:omnilect/features/sync/manager/scope_state.dart';

/// Top-level description of which logical op (if any) the sync manager is
/// currently running. The UI uses this to render the home-screen loading
/// indicator and to pick the "currently relevant" scope.
sealed class CurrentOp {
  const CurrentOp();
  String get scopeId;
}

final class NoOp extends CurrentOp {
  const NoOp();
  @override
  String get scopeId => '';
}

final class FullSyncOpInfo extends CurrentOp {
  const FullSyncOpInfo();
  @override
  String get scopeId => ScopeIds.allCourses;
}

final class ListsRefreshOpInfo extends CurrentOp {
  const ListsRefreshOpInfo();
  @override
  String get scopeId => ScopeIds.lists;
}

final class CourseSyncOpInfo extends CurrentOp {
  const CourseSyncOpInfo(this.courseId);
  final String courseId;
  @override
  String get scopeId => ScopeIds.course(courseId);
}

final class LectureSyncOpInfo extends CurrentOp {
  const LectureSyncOpInfo(this.courseId, this.sequenceId);
  final String courseId;
  final String sequenceId;
  @override
  String get scopeId => ScopeIds.lecture(sequenceId);
}

/// Main-isolate mirror of the sync isolate's state. Built up from
/// sync events by the bridge and exposed to the UI via
/// `syncManagerStateProvider`.
@immutable
class SyncManagerState {
  const SyncManagerState({
    this.currentOp = const NoOp(),
    this.scopeStates = const <String, ScopeState>{},
    this.reauthPending = false,
  });

  final CurrentOp currentOp;
  final Map<String, ScopeState> scopeStates;
  final bool reauthPending;

  ScopeState scope(String scopeId) =>
      scopeStates[scopeId] ?? const ScopeState();

  SyncManagerState copyWith({
    CurrentOp? currentOp,
    Map<String, ScopeState>? scopeStates,
    bool? reauthPending,
  }) {
    return SyncManagerState(
      currentOp: currentOp ?? this.currentOp,
      scopeStates: scopeStates ?? this.scopeStates,
      reauthPending: reauthPending ?? this.reauthPending,
    );
  }

  SyncManagerState withScope(String scopeId, ScopeState state) {
    final next = Map<String, ScopeState>.from(scopeStates);
    if (state.status == ScopeStatus.idle &&
        state.completed == 0 &&
        state.total == 0) {
      next.remove(scopeId);
    } else {
      next[scopeId] = state;
    }
    return copyWith(scopeStates: Map.unmodifiable(next));
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncManagerState &&
        other.currentOp == currentOp &&
        other.reauthPending == reauthPending &&
        _mapEquals(other.scopeStates, scopeStates);
  }

  @override
  int get hashCode => Object.hash(
        currentOp,
        reauthPending,
        // Best-effort hash — map is unordered.
        scopeStates.length,
      );

  static bool _mapEquals(
    Map<String, ScopeState> a,
    Map<String, ScopeState> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
