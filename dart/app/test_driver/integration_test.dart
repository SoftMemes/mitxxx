// Driver half of the integration_test screenshot run. `flutter drive`
// spawns this on the host and the test file on the device; the binding's
// `takeScreenshot(name)` calls hop over here, and we write the PNG to
// `screenshots/raw/` next to pubspec.yaml.

import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final outDir = Directory('screenshots/raw')..createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [_]) async {
      final file = File('${outDir.path}/$name.png');
      await file.writeAsBytes(bytes);
      stdout.writeln('wrote ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
