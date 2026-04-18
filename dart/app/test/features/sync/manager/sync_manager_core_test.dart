import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/stale_session.dart';
import 'package:omnilect/features/sync/isolate/sync_manager_core.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// A test double that doesn't do any real work — it just completes when the
/// test tells it to.
class _FakeOp extends LogicalOp {
  _FakeOp({
    required super.request,
    required super.cancelToken,
    required super.events,
  });

  final Completer<void> completer = Completer<void>();
  bool ran = false;
  bool cancelObserved = false;

  @override
  Future<void> run() async {
    ran = true;
    // Cooperatively observe cancellation.
    unawaited(cancelToken.whenCancel.then((_) {
      cancelObserved = true;
      if (!completer.isCompleted) {
        completer.completeError(DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: cancelToken.cancelError?.message ?? 'cancelled',
        ));
      }
    }));
    return completer.future;
  }

  void completeSuccess() {
    if (!completer.isCompleted) completer.complete();
  }

  void completeWithStale(SessionKind kind) {
    if (!completer.isCompleted) {
      completer.completeError(StaleSessionException(kind));
    }
  }

  void completeWithError(Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  }
}

class _FakeOpFactory {
  final List<_FakeOp> built = [];

  LogicalOp build(SyncRequest request, CancelToken token, EventSink<SyncEvent> events) {
    final op = _FakeOp(request: request, cancelToken: token, events: events);
    built.add(op);
    return op;
  }
}

/// Captures every event emitted by the core so assertions can inspect them.
class _EventRecorder implements EventSink<SyncEvent> {
  final List<SyncEvent> all = [];
  bool closed = false;

  @override
  void add(SyncEvent event) => all.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  void close() => closed = true;

  Iterable<T> ofType<T>() => all.whereType<T>();
}

/// Give queued microtasks and futures (including `whenCancel.then(...)`
/// chains and the state machine's own `_runAndFinalise` error path) enough
/// turns to resolve. A single `Future<void>.delayed(Duration.zero)` only runs
/// one microtask; cancel-and-replace needs several hops through the event
/// queue before the replacement op is live.
Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('SyncManagerCore', () {
    late _EventRecorder events;
    late _FakeOpFactory factory;
    late SyncManagerCore core;

    setUp(() {
      events = _EventRecorder();
      factory = _FakeOpFactory();
      core = SyncManagerCore(events: events, opFactory: factory.build);
    });

    test('starts running on first request', () async {
      core.submit(const FullSyncRequest());
      await flush();

      expect(factory.built, hasLength(1));
      expect(factory.built.first.ran, isTrue);
      expect(core.runningScopeId, 'all-courses');
      expect(events.ofType<OpStarted>(), hasLength(1));
    });

    test('debounces identical in-flight request (same scope id)', () async {
      core
        ..submit(const FullSyncRequest())
        ..submit(const FullSyncRequest());
      await flush();

      expect(factory.built, hasLength(1));
      expect(events.ofType<OpStarted>(), hasLength(1));
    });

    test('cancel-and-replace when scope differs', () async {
      core.submit(const FullSyncRequest());
      // Wait just long enough for the op to start but not long enough for
      // the cancel chain to resolve — a single microtask.
      await Future<void>.delayed(Duration.zero);
      expect(core.runningScopeId, 'all-courses');

      core.submit(const CourseSyncRequest('course-1'));
      // Immediately after the second submit, we're mid-cancellation.
      expect(core.isCancelling, isTrue);
      expect(core.pendingScopeId, 'course:course-1');

      // Drain the cancel chain: whenCancel → completer.completeError →
      // _runAndFinalise → _onOpDone → _start(next).
      await flush();

      expect(factory.built.first.cancelObserved, isTrue);
      expect(factory.built, hasLength(2));
      expect(core.runningScopeId, 'course:course-1');
      expect(events.ofType<OpCancelled>(), hasLength(1));
      expect(events.ofType<OpStarted>().map((e) => e.scopeId),
          ['all-courses', 'course:course-1']);
    });

    test('cancelling.next is overwritten on rapid-fire replacements', () async {
      core.submit(const FullSyncRequest());
      await Future<void>.delayed(Duration.zero);
      core
        ..submit(const CourseSyncRequest('course-1'))
        ..submit(const CourseSyncRequest('course-2'));

      // Synchronously after the second replacement, pending is course-2.
      expect(core.pendingScopeId, 'course:course-2');

      await flush();

      // course-1 is never built — overwritten while cancelling.
      expect(factory.built, hasLength(2));
      expect(factory.built.last.request.scopeId, 'course:course-2');
      expect(core.runningScopeId, 'course:course-2');
    });

    test('stale-session: transitions to AwaitingSessionRefresh', () async {
      core.submit(const FullSyncRequest());
      await flush();

      factory.built.first.completeWithStale(SessionKind.lms);
      await flush();

      expect(core.awaitingSessionRefreshKind, SessionKind.lms);
      expect(core.pendingScopeId, 'all-courses');
      expect(events.ofType<SessionRefreshRequired>(), hasLength(1));
    });

    test('SessionRefreshCompleted resumes with the pending request (overwritten)',
        () async {
      core.submit(const FullSyncRequest());
      await flush();
      factory.built.first.completeWithStale(SessionKind.mitxonline);
      await flush();

      // User requests something else while the reauth dialog is up.
      core.submit(const CourseSyncRequest('course-9'));
      expect(core.pendingScopeId, 'course:course-9');

      // Reauth completes.
      core.onSessionRefreshCompleted(SessionKind.mitxonline);
      await flush();

      expect(factory.built, hasLength(2));
      expect(core.runningScopeId, 'course:course-9');
    });

    test('SessionRefreshFailed goes idle and emits OpCancelled', () async {
      core.submit(const FullSyncRequest());
      await flush();
      factory.built.first.completeWithStale(SessionKind.mitxonline);
      await flush();

      core.onSessionRefreshFailed(SessionKind.mitxonline, 'user dismissed');
      expect(core.isIdle, isTrue);
      expect(events.ofType<OpCancelled>(), hasLength(1));
    });

    test('stopAndWait(drain:true) awaits in-flight drain', () async {
      core.submit(const FullSyncRequest());
      await Future<void>.delayed(Duration.zero);
      expect(core.runningScopeId, 'all-courses');

      final stopFuture = core.stopAndWait();
      expect(core.isCancelling, isTrue);

      await stopFuture;
      expect(core.isIdle, isTrue);
      expect(factory.built.first.cancelObserved, isTrue);
    });

    test('terminal error (non-auth) goes to idle and emits OpErrored', () async {
      core.submit(const FullSyncRequest());
      await flush();

      factory.built.first.completeWithError(StateError('boom'));
      await flush();

      expect(core.isIdle, isTrue);
      expect(events.ofType<OpErrored>(), hasLength(1));
    });

    test('clean completion emits OpCompleted and goes idle', () async {
      core.submit(const FullSyncRequest());
      await flush();

      factory.built.first.completeSuccess();
      await flush();

      expect(core.isIdle, isTrue);
      expect(events.ofType<OpCompleted>(), hasLength(1));
    });
  });
}
