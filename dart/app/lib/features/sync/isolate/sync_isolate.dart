import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart' show RootIsolateToken;
import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/sync_isolate_entry.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

final _log = Logger('sync-isolate.spawn');

/// Main-isolate handle to the sync isolate. Owns the [Isolate], both
/// [ReceivePort]/[SendPort]s, and exposes a broadcast event stream. Spawned
/// by `SyncManager` after authentication; shut down on sign-out.
class SyncIsolate {
  SyncIsolate._(this._isolate, this._fromIsolate, this._toIsolate);

  final Isolate _isolate;
  final ReceivePort _fromIsolate;
  final SendPort _toIsolate;

  /// Fan-out of every [SyncEvent] emitted by the isolate, including control
  /// events like [IsolateReady] and [IsolateExited].
  late final Stream<SyncEvent> events = _fromIsolate
      .cast<Object?>()
      .where((msg) => msg is SyncEvent)
      .cast<SyncEvent>()
      .asBroadcastStream();

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
    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError('RootIsolateToken.instance is null');
    }
    final fromIsolate = ReceivePort('sync-isolate-rx');
    final handshake = Completer<SendPort>();

    late StreamSubscription<dynamic> sub;
    sub = fromIsolate.listen((msg) {
      if (msg is SendPort && !handshake.isCompleted) {
        handshake.complete(msg);
        sub.cancel();
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
    return SyncIsolate._(isolate, fromIsolate, toIsolate);
  }
}
