import 'dart:async';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:omnilect/features/sync/isolate/sync_messages.dart';

/// Subscribes to `Logger.root` inside the sync isolate and forwards every
/// record to the main isolate as a [LogRecordForwarded] event. Paired with
/// `MainLoggerReceiver` on the main-isolate bridge so existing listeners
/// (`dev.log`, Crashlytics, etc.) keep working unchanged.
class IsolateLoggerBridge {
  IsolateLoggerBridge(this._toMain);

  final SendPort _toMain;
  StreamSubscription<LogRecord>? _sub;

  void start() {
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen((record) {
      _toMain.send(LogRecordForwarded(
        level: record.level.value,
        loggerName: record.loggerName,
        message: record.message,
        time: record.time,
        error: record.error?.toString(),
        stackTrace: record.stackTrace?.toString(),
      ));
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}

/// Main-isolate side: re-emits forwarded records under a
/// `Logger('sync-isolate')` namespace so the main isolate's existing log
/// pipeline picks them up.
void applyForwardedLogRecord(LogRecordForwarded event) {
  Logger('sync-isolate.${event.loggerName}').log(
    _levelFromValue(event.level),
    event.message,
    event.error,
    event.stackTrace == null ? null : StackTrace.fromString(event.stackTrace!),
  );
}

Level _levelFromValue(int v) {
  for (final level in Level.LEVELS) {
    if (level.value == v) return level;
  }
  return Level.INFO;
}
