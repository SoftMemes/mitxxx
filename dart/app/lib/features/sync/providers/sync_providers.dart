// ignore_for_file: uri_has_not_been_generated
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/core/network/dio_client_provider.dart';
import 'package:omnilect/features/auth/providers/auth_provider.dart';
import 'package:omnilect/features/auth/providers/reauth_provider.dart';
import 'package:omnilect/features/sync/bridge/session_refresh_manager.dart';
import 'package:omnilect/features/sync/bridge/sync_event_bridge.dart';
import 'package:omnilect/features/sync/bridge/sync_event_ring_buffer.dart';
import 'package:omnilect/features/sync/isolate/sync_isolate.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_providers.g.dart';

final _log = Logger('sync.providers');

/// Owns the [SyncManager] for the signed-in session.
///
/// Returns `null` before auth is established and after sign-out. When auth
/// transitions from non-null → null, Riverpod disposes this provider — our
/// `onDispose` tears down the bridges and shuts the isolate down.
///
/// Consumers that need the manager synchronously (UI fire-and-forget
/// requests) should use [syncManagerOrNull] and guard on `null`.
@Riverpod(keepAlive: true)
Future<SyncManager?> syncManager(Ref ref) async {
  final auth = ref.watch(authProvider);
  final user = auth.value;
  if (user == null) {
    _log.info('syncManagerProvider: auth not ready — manager is null');
    return null;
  }

  _log.info('syncManagerProvider: spawning sync isolate');
  final isolate = await SyncIsolate.spawn();
  final manager = SyncManager(isolate);

  // Wait for the isolate's readiness handshake before accepting requests.
  try {
    await manager.events
        .firstWhere((e) => e is IsolateReady)
        .timeout(const Duration(seconds: 10));
    _log.info('syncManagerProvider: IsolateReady received');
  } on Object catch (e, st) {
    _log.severe('sync isolate readiness timed out', e, st);
    await manager.dispose();
    rethrow;
  }

  final sessionRefresh = SessionRefreshManager(
    syncManager: manager,
    client: ref.read(dioClientProvider),
    reauthController: ref.read(reauthControllerProvider.notifier),
  );
  final eventBridge = SyncEventBridge(syncManager: manager, ref: ref);
  _log.info('syncManagerProvider: bridges wired — manager is live');

  ref.onDispose(() async {
    _log.info('syncManagerProvider: disposing');
    await eventBridge.dispose();
    await sessionRefresh.dispose();
    await manager.dispose();
  });

  return manager;
}

/// Synchronous accessor that returns `null` until [syncManagerProvider]
/// resolves. Use this from UI fire-and-forget request sites — a `null`
/// manager means sync isn't available yet (e.g. pre-auth cold start).
@riverpod
SyncManager? syncManagerOrNull(Ref ref) {
  return ref.watch(syncManagerProvider).value;
}

/// Streams the current [SyncManagerState]. Emits the empty state while the
/// manager is still constructing or absent.
@riverpod
Stream<SyncManagerState> syncManagerState(Ref ref) async* {
  final manager = ref.watch(syncManagerOrNullProvider);
  if (manager == null) {
    yield const SyncManagerState();
    return;
  }
  yield manager.state;
  yield* manager.stateStream;
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
  final manager = ref.watch(syncManagerOrNullProvider);
  if (manager == null) return const Stream.empty();
  return manager.events;
}

/// Bounded ring buffer of recent [SyncEvent]s for the dev debugger. Rebinds
/// whenever the underlying sync manager changes (e.g. sign-out → sign-in).
@Riverpod(keepAlive: true)
SyncEventRingBuffer syncEventRingBuffer(Ref ref) {
  final buffer = SyncEventRingBuffer();
  final manager = ref.watch(syncManagerOrNullProvider);
  if (manager != null) {
    buffer.bind(manager.events);
  }
  ref.onDispose(buffer.dispose);
  return buffer;
}
