import 'dart:async';

import 'package:logging/logging.dart';
import 'package:omnilect/core/analytics/analytics_events.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_isolate.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';
import 'package:omnilect/features/sync/manager/scope_state.dart';
import 'package:omnilect/features/sync/manager/sync_manager_state.dart';

final _log = Logger('sync-manager');

/// Main-isolate facade over [SyncIsolate]. UI code uses this class to
/// request sync work. Every public method is fire-and-forget: they send a
/// message and return immediately. UI observes progress via
/// `syncManagerStateProvider`.
class SyncManager {
  SyncManager(this._isolate) {
    _sub = _isolate.events.listen(_onEvent);
  }

  final SyncIsolate _isolate;
  late final StreamSubscription<SyncEvent> _sub;

  final _stateController =
      StreamController<SyncManagerState>.broadcast(sync: true);
  SyncManagerState _state = const SyncManagerState();

  SyncManagerState get state => _state;
  Stream<SyncManagerState> get stateStream => _stateController.stream;

  /// Every [SyncEvent] as it comes in. Exposed for the dev debugger + the
  /// download-coordination bridge + analytics dispatcher.
  final _eventsController = StreamController<SyncEvent>.broadcast(sync: true);
  Stream<SyncEvent> get events => _eventsController.stream;

  /// One-shot completer populated from [_onEvent] the first time the isolate
  /// reports terminal-to-startup state. Using a Completer — not a
  /// `firstWhere` on the broadcast stream — avoids a race where `IsolateReady`
  /// arrives before any subscriber attaches and gets silently dropped.
  final _ready = Completer<void>();
  Future<void> get ready => _ready.future;

  /// True iff the isolate terminated during startup. Checked by
  /// `syncManagerProvider` after [ready] resolves so it can fail fast instead
  /// of treating a dead isolate as live.
  bool _isolateExited = false;
  bool get isolateExited => _isolateExited;

  // --- UI-facing request API ---------------------------------------------

  void requestFullSync({String trigger = kTriggerManual}) {
    _log.info('requestFullSync trigger=$trigger');
    _isolate.send(FullSyncRequest(trigger: trigger));
  }

  void requestListsRefresh({String trigger = kTriggerManual}) {
    _log.info('requestListsRefresh trigger=$trigger');
    _isolate.send(ListsRefreshRequest(trigger: trigger));
  }

  void requestCourseSync(String courseId, {String trigger = kTriggerManual}) {
    _log.info('requestCourseSync course=$courseId trigger=$trigger');
    _isolate.send(CourseSyncRequest(courseId, trigger: trigger));
  }

  void requestLectureSync(
    String courseId,
    String sequenceId, {
    String trigger = kTriggerManual,
  }) {
    _log.info(
      'requestLectureSync course=$courseId seq=$sequenceId trigger=$trigger',
    );
    _isolate.send(LectureSyncRequest(courseId, sequenceId, trigger: trigger));
  }

  /// Refresh the `available_lists` cache on the sync isolate and await a
  /// terminal outcome. Returns on [OpCompleted]; throws on [OpErrored];
  /// completes normally on [OpCancelled] (cancel-and-replace is expected
  /// during rapid interactions).
  ///
  /// Unlike the other request methods, this returns a [Future] so the
  /// settings/onboarding RefreshIndicator can collapse at the right moment.
  Future<void> refreshAvailableLists({
    String trigger = kTriggerManual,
  }) async {
    _log.info('refreshAvailableLists trigger=$trigger');
    final completer = Completer<void>();
    late StreamSubscription<SyncEvent> sub;
    sub = events.listen((event) {
      void finish(FutureOr<void> Function() complete) {
        if (completer.isCompleted) return;
        complete();
        unawaited(sub.cancel());
      }

      if (event is OpCompleted && event.scopeId == ScopeIds.availableLists) {
        finish(completer.complete);
      } else if (event is OpCancelled &&
          event.scopeId == ScopeIds.availableLists) {
        // Cancel-and-replace: treat as a "done enough" signal — the UI
        // spinner should collapse, a subsequent op is running in its place.
        finish(completer.complete);
      } else if (event is OpErrored &&
          event.scopeId == ScopeIds.availableLists) {
        finish(() => completer.completeError(StateError(event.message)));
      }
    });
    _isolate.send(AvailableListsRefreshRequest(trigger: trigger));
    return completer.future;
  }

  /// Cancel any in-flight op and wait for it to drain. Used by sign-out +
  /// "delete all app data" before wiping the DB.
  Future<void> stopAndWait() async {
    _isolate.send(const StopAll());
    // Wait for an OpCancelled OR an OpCompleted if the op finishes naturally
    // before cancel takes effect. If no op is running, the isolate just
    // ignores the StopAll.
    if (_state.currentOp is NoOp) return;
    await events
        .where((e) => e is OpCancelled || e is OpCompleted)
        .first
        .timeout(const Duration(seconds: 10), onTimeout: () {
      _log.warning('stopAndWait: timed out');
      return const OpCancelled('');
    });
  }

  /// Main-isolate side has finished reauth / session refresh and cookies on
  /// disk are fresh. Tells the isolate to restart the pending request.
  void signalSessionRefreshCompleted(SessionKind kind) {
    _isolate.send(SessionRefreshCompleted(kind));
  }

  /// Main-isolate side gave up on reauth (user dismissed, bootstrap failed).
  /// The isolate will drop the pending request.
  void signalSessionRefreshFailed(SessionKind kind, [String? reason]) {
    _isolate.send(SessionRefreshFailed(kind, reason));
  }

  /// Force the isolate to reload the cookie jar from disk (e.g. after a
  /// non-reauth cookie change).
  void reloadCookies() => _isolate.send(const ReloadCookies());

  /// Dispose: shut down the isolate and close streams. Callers should
  /// `await` this.
  Future<void> dispose() async {
    await _sub.cancel();
    await _isolate.shutdown();
    await _stateController.close();
    await _eventsController.close();
  }

  // --- Event → state mirroring -------------------------------------------

  void _onEvent(SyncEvent event) {
    // Resolve the readiness completer the moment the isolate tells us it's
    // up — or that it's already dead. This is the reliable signal for
    // `syncManagerProvider` to finish its build; awaiting the broadcast
    // stream would race the constructor-time delivery of buffered events.
    if (event is IsolateReady && !_ready.isCompleted) {
      _ready.complete();
    } else if (event is IsolateExited) {
      _isolateExited = true;
      if (!_ready.isCompleted) _ready.complete();
    }
    _eventsController.add(event);
    final next = _apply(_state, event);
    if (!identical(next, _state)) {
      _state = next;
      _stateController.add(next);
    }
  }

  static SyncManagerState _apply(SyncManagerState s, SyncEvent event) {
    switch (event) {
      case OpStarted():
        return s.copyWith(currentOp: _currentOpFromScope(event.scopeId));
      case OpCompleted():
        return s.copyWith(currentOp: const NoOp());
      case OpCancelled():
        return s.copyWith(currentOp: const NoOp());
      case OpErrored():
        return s.copyWith(currentOp: const NoOp());
      case ScopeStateChanged():
        return s.withScope(event.scopeId, event.state);
      case SubtaskProgress():
        final existing = s.scope(event.scopeId);
        return s.withScope(
          event.scopeId,
          existing.copyWith(
            completed: event.completed,
            total: event.total,
          ),
        );
      case SessionRefreshRequired():
        return s.copyWith(reauthPending: true);
      case IsolateReady():
      case IsolateExited():
      case RemovedVideoUrls():
      case AnalyticsEventForwarded():
      case LogRecordForwarded():
      case DbInvalidated():
      case PrefetchCourseImages():
      case ValidateTrackedLecture():
        return s;
    }
  }

  static CurrentOp _currentOpFromScope(String scopeId) {
    if (scopeId == ScopeIds.allCourses) return const FullSyncOpInfo();
    if (scopeId == ScopeIds.lists) return const ListsRefreshOpInfo();
    if (scopeId.startsWith('course:')) {
      return CourseSyncOpInfo(scopeId.substring('course:'.length));
    }
    if (scopeId.startsWith('lecture:')) {
      // We don't know the courseId from the scope id alone; the UI only
      // needs the sequence id for this op's loading state.
      return LectureSyncOpInfo('', scopeId.substring('lecture:'.length));
    }
    return const NoOp();
  }
}
