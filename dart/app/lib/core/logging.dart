import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Call once in main() before runApp.
void initLogging() {
  // In release builds keep logging off to avoid leaking session details.
  if (!kDebugMode) return;

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final t = record.time;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    final ts = '$hh:$mm:$ss.$ms';
    final level = record.level.name.padRight(7);
    debugPrint('$ts [$level] ${record.loggerName}: ${record.message}');
    if (record.error != null) debugPrint('  error: ${record.error}');
    if (record.stackTrace != null) debugPrint(record.stackTrace.toString());
  });
}
