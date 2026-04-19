import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/sync_isolate_entry.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

final _log = Logger('sync-isolate.spawn');

/// Main-isolate handle to the sync isolate. Owns the [Isolate], the
/// [ReceivePort], and exposes a broadcast event stream. Spawned by
/// `SyncManager` after authentication; shut down on sign-out.
class SyncIsolate {
  SyncIsolate._(
    this._isolate,
    this._fromIsolate,
    this._toIsolate,
    this.events,
  );

  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  final SendPort _toIsolate;

  /// Fan-out of every [SyncEvent] emitted by the isolate, including control
  /// events like [IsolateReady] and [IsolateExited]. Derived from the single
  /// broadcast wrapper around [_fromIsolate] that was created in [spawn];
  /// the underlying [ReceivePort] is single-subscription and can't be
  /// listened to twice, which is why both the handshake listener and every
  /// downstream consumer (SyncManager, shutdown, tests) share one broadcast.
  final Stream<SyncEvent> events;

  /// Sends a message to the isolate. Accepts [SyncRequest]s and control
  /// messages ([SessionRefreshCompleted], [StopAll], [Shutdown], etc.).
  void send(Object message) => _toIsolate.send(message);

  /// Gracefully shut down: send [Shutdown], wait for [IsolateExited] ack,
  /// then kill the isolate. Caller should still await this.
  Future<void> shutdown() async {
    final done = events.firstWhere((e) => e is IsolateExited).timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _log.warning('shutdown: no IsolateExited ack; killing');
        return const IsolateExited();
      },
    );
    _toIsolate.send(const Shutdown());
    await done;
    _isolate.kill(priority: Isolate.immediate);
    _fromIsolate.close();
  }

  /// Spawn the sync isolate and wait for the initial handshake (the
  /// isolate's SendPort) before returning.
  static Future<SyncIsolate> spawn() async {
    _log.info('spawn: starting sync isolate');
    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError('RootIsolateToken.instance is null');
    }
    final fromIsolate = ReceivePort('sync-isolate-rx');

    // ONE broadcast wrapper over the ReceivePort. The handshake listener
    // (waiting for the isolate's SendPort) and every downstream consumer
    // (SyncManager + shutdown's firstWhere) subscribe to this same
    // broadcast — the ReceivePort itself is single-subscription and would
    // throw `Stream has already been listened to` on any re-listen.
    final rawBroadcast = fromIsolate.asBroadcastStream();

    // Downstream view: the SendPort handshake message is not a SyncEvent
    // and must be filtered out before events reaches consumers. Derived
    // `.where()`/`.cast()` on a broadcast stream stay broadcast, so the
    // final `events` stream supports multiple listeners.
    final events = rawBroadcast
        .where((msg) => msg is SyncEvent)
        .cast<SyncEvent>();

    final handshake = Completer<SendPort>();
    late StreamSubscription<dynamic> handshakeSub;
    handshakeSub = rawBroadcast.listen((msg) {
      if (msg is SendPort && !handshake.isCompleted) {
        handshake.complete(msg);
        handshakeSub.cancel();
      }
    });

    final isolate = await Isolate.spawn<SpawnBundle>(
      syncIsolateEntry,
      SpawnBundle(rootToken: token, mainPort: fromIsolate.sendPort),
      debugName: 'sync-isolate',
      errorsAreFatal: false,
    );

    final toIsolate = await handshake.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        isolate.kill(priority: Isolate.immediate);
        fromIsolate.close();
        throw StateError('sync isolate did not hand over SendPort');
      },
    );

    _log.info('sync isolate spawned');
    return SyncIsolate._(isolate, fromIsolate, toIsolate, events);
  }
}
