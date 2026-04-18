import 'dart:async';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

final _log = Logger('sync-core');

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

sealed class _State {
  const _State();
}

final class _Idle extends _State {
  const _Idle();
}

final class _Running extends _State {
  _Running(this.op);
  final LogicalOp op;
}

final class _Cancelling extends _State {
  _Cancelling(this.prev, this.next);
  final LogicalOp prev;
  SyncRequest? next;
}

final class _AwaitingSessionRefresh extends _State {
  _AwaitingSessionRefresh(this.kind, this.pending);
  final SessionKind kind;
  SyncRequest pending;
}

// ---------------------------------------------------------------------------
// SyncManagerCore — the pure state machine
// ---------------------------------------------------------------------------

/// The core sync state machine. Lives inside the sync isolate but has no
/// HTTP / DB / isolate-plumbing dependencies of its own — it drives
/// [LogicalOp]s built by the injected [OpFactory].
///
/// Contract:
/// - At most one [LogicalOp] runs at a time.
/// - A request identical to the current op is a no-op (debounce).
/// - A request with a different scope cancels the current op and replaces it.
/// - When a sub-task throws [StaleSessionException], the core emits
///   [SessionRefreshRequired] and waits for [onSessionRefreshCompleted] /
///   [onSessionRefreshFailed] before deciding what to do next.
class SyncManagerCore {
  SyncManagerCore({
    required EventSink<SyncEvent> events,
    required OpFactory opFactory,
  })  : _events = events,
        _opFactory = opFactory;

  final EventSink<SyncEvent> _events;
  final OpFactory _opFactory;
  _State _state = const _Idle();

  /// For `stopAndWait` / `StopAll` callers: returns a future that resolves
  /// when the state machine is idle (no running op, no queued next).
  Completer<void>? _idleCompleter;

  /// Submit a user request. Fire-and-forget — callers do not await this.
  void submit(SyncRequest req) {
    final s = _state;
    switch (s) {
      case _Idle():
        _start(req);
      case _Running(op: final op):
        if (op.request.sameAs(req)) {
          _log.fine('debounced request for ${req.scopeId}');
          return;
        }
        _log.info('cancel-and-replace: ${op.request.scopeId} → ${req.scopeId}');
        _state = _Cancelling(op, req);
        op.cancelToken.cancel('replaced by ${req.scopeId}');
      case _Cancelling():
        _log.info('overwriting cancelling.next → ${req.scopeId}');
        s.next = req;
      case _AwaitingSessionRefresh():
        _log.info('overwriting pending (awaiting reauth) → ${req.scopeId}');
        s.pending = req;
    }
  }

  /// Main isolate finished a session refresh; start the latest pending
  /// request (or go idle if [kind] doesn't match what we were waiting for —
  /// defensive, shouldn't happen in normal flow).
  void onSessionRefreshCompleted(SessionKind kind) {
    final s = _state;
    if (s is! _AwaitingSessionRefresh) {
      _log.warning('SessionRefreshCompleted($kind) ignored; state=$s');
      return;
    }
    if (s.kind != kind) {
      _log.warning('SessionRefreshCompleted($kind) but awaiting ${s.kind}');
      return;
    }
    _start(s.pending);
  }

  /// Main isolate couldn't refresh the session (user dismissed, silent
  /// bootstrap failed). Drop the pending request.
  void onSessionRefreshFailed(SessionKind kind, [String? reason]) {
    final s = _state;
    if (s is! _AwaitingSessionRefresh) {
      _log.warning('SessionRefreshFailed($kind) ignored; state=$s');
      return;
    }
    if (s.kind != kind) {
      _log.warning('SessionRefreshFailed($kind) but awaiting ${s.kind}');
      return;
    }
    _events.add(OpCancelled(s.pending.scopeId));
    _state = const _Idle();
    _signalIdle();
  }

  /// Cancel the current op and (optionally) await in-flight drain.
  ///
  /// [drain=true] resolves only when any in-flight op has finished draining.
  /// [drain=false] resolves immediately after firing the cancel token.
  Future<void> stopAndWait({bool drain = true}) async {
    final s = _state;
    switch (s) {
      case _Idle():
        return;
      case _Running(op: final op):
        _state = _Cancelling(op, null);
        op.cancelToken.cancel('stopAndWait');
      case _Cancelling():
        s.next = null;
      case _AwaitingSessionRefresh():
        _events.add(OpCancelled(s.pending.scopeId));
        _state = const _Idle();
        _signalIdle();
        return;
    }
    if (!drain) return;
    _idleCompleter ??= Completer<void>();
    return _idleCompleter!.future;
  }

  /// Test-only: is the state machine currently idle?
  bool get isIdle => _state is _Idle;

  /// Test-only: scope id of the currently running op, or null.
  String? get runningScopeId {
    final s = _state;
    return s is _Running ? s.op.request.scopeId : null;
  }

  /// Test-only: is the state machine currently cancelling?
  bool get isCancelling => _state is _Cancelling;

  /// Test-only: the scope id of the latest pending request when awaiting
  /// session refresh / cancelling, else null.
  String? get pendingScopeId {
    final s = _state;
    if (s is _AwaitingSessionRefresh) return s.pending.scopeId;
    if (s is _Cancelling) return s.next?.scopeId;
    return null;
  }

  /// Test-only: is a session-refresh currently being awaited?
  SessionKind? get awaitingSessionRefreshKind {
    final s = _state;
    return s is _AwaitingSessionRefresh ? s.kind : null;
  }

  // --- Private ----------------------------------------------------------

  void _start(SyncRequest req) {
    final token = CancelToken();
    final op = _opFactory(req, token, _events);
    _state = _Running(op);
    _events.add(OpStarted(req.scopeId, req.trigger, DateTime.now()));
    _log.info('op start: ${req.scopeId} (trigger=${req.trigger})');
    unawaited(_runAndFinalise(op));
  }

  Future<void> _runAndFinalise(LogicalOp op) async {
    try {
      await op.run();
      _onOpDone(op, error: null, staleKind: null);
    } on StaleSessionException catch (e) {
      _onOpDone(op, error: e, staleKind: e.kind);
    } on Object catch (e, st) {
      _log.warning('op ${op.request.scopeId} crashed', e, st);
      _onOpDone(op, error: e, staleKind: null);
    }
  }

  void _onOpDone(LogicalOp op, {required Object? error, required SessionKind? staleKind}) {
    final s = _state;

    // Case A: cancel-and-replace path — start the queued next request.
    if (s is _Cancelling && identical(s.prev, op)) {
      _events.add(OpCancelled(op.request.scopeId));
      final next = s.next;
      if (next != null) {
        _start(next);
      } else {
        _state = const _Idle();
        _signalIdle();
      }
      return;
    }

    // Case B: sub-task raised 401/403 and bubbled up.
    if (staleKind != null) {
      _events.add(SessionRefreshRequired(staleKind));
      _state = _AwaitingSessionRefresh(staleKind, op.request);
      return;
    }

    // Case C: terminal error.
    if (error != null) {
      _events.add(OpErrored(op.request.scopeId, error.toString()));
      _state = const _Idle();
      _signalIdle();
      return;
    }

    // Case D: clean completion.
    _events.add(OpCompleted(op.request.scopeId, DateTime.now()));
    _state = const _Idle();
    _signalIdle();
  }

  void _signalIdle() {
    final c = _idleCompleter;
    if (c != null && !c.isCompleted) {
      _idleCompleter = null;
      c.complete();
    }
  }
}
