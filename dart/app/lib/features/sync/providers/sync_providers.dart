// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_providers.g.dart';

/// Holds the [SyncManager] for the app's lifetime.
///
/// This provider MUST be overridden at app startup (see
/// `SyncLifecycleObserver`) — the sync manager can't be constructed from a
/// Ref because spawning the isolate is async and requires the
/// `RootIsolateToken`. The default `build` throws to catch misconfiguration.
@Riverpod(keepAlive: true)
SyncManager syncManager(Ref ref) {
  throw StateError(
    'syncManagerProvider must be overridden at app startup after '
    'the sync isolate has spawned. See SyncLifecycleObserver.',
  );
}

/// Streams the current [SyncManagerState] for the UI.
@riverpod
Stream<SyncManagerState> syncManagerState(Ref ref) {
  final manager = ref.watch(syncManagerProvider);
  return manager.stateStream;
}

/// True while a full sync OR lists-refresh is running — drives the home
/// screen's pull-to-refresh spinner and top-of-list progress bar.
@riverpod
bool isSyncingAll(Ref ref) {
  final state = ref.watch(syncManagerStateProvider).value;
  if (state == null) return false;
  final op = state.currentOp;
  return op is FullSyncOpInfo || op is ListsRefreshOpInfo;
}

/// Per-course scope state (idle / scheduled / syncing / error).
@riverpod
ScopeState courseScopeState(Ref ref, String courseId) {
  final state = ref.watch(syncManagerStateProvider).value;
  if (state == null) return const ScopeState();
  return state.scope(ScopeIds.course(courseId));
}

/// Per-sequence (lecture) scope state.
@riverpod
ScopeState lectureScopeState(Ref ref, String sequenceId) {
  final state = ref.watch(syncManagerStateProvider).value;
  if (state == null) return const ScopeState();
  return state.scope(ScopeIds.lecture(sequenceId));
}

/// Raw event stream for the dev debugger / bridge dispatchers. Consumers
/// should prefer one of the derived providers above for UI use.
@riverpod
Stream<SyncEvent> syncEvents(Ref ref) {
  final manager = ref.watch(syncManagerProvider);
  return manager.events;
}
