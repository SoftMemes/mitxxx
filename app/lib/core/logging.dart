import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Call once in main() before runApp.
void initLogging() {
  // In release builds keep logging off to avoid leaking session details.
  if (!kDebugMode) return;

  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    dev.log(
      record.message,
      time: record.time,
      name: record.loggerName,
      level: record.level.value,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  });
}
