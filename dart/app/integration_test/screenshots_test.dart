// Drives the app through onboarding → login → list selection → home →
// course outline → lecture, capturing a PNG at each stop. The driver
// file (`test_driver/integration_test.dart`) writes them to the caller's
// `screenshots/raw/` directory.
//
// Run via `scripts/screenshots.sh` (recommended — handles credentials
// and simulator boot). Direct invocation:
//
//   fvm flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart \
//     --flavor=dev \
//     --dart-define=SCREENSHOT_MODE=true \
//     --dart-define=SCREENSHOT_EMAIL=... \
//     --dart-define=SCREENSHOT_PASSWORD=...
//
// Uses a real login + real sync. Point it at a dedicated MITx account.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omnilect/flavor_config.dart';
import 'package:omnilect/main.dart';

const _kSyncTimeout = Duration(minutes: 5);
const _kInteractionTimeout = Duration(seconds: 30);

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = _kInteractionTimeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TimeoutException('Timed out waiting for $finder');
}

Future<void> _shoot(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 200),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
  // Android: convert the Flutter surface to an image before reading pixels.
  // iOS treats this as a no-op.
  await binding.convertFlutterSurfaceToImage();
  await binding.takeScreenshot(name);
}

Finder _byTypeName(String name) => find.byElementPredicate(
      (e) => e.widget.runtimeType.toString() == name,
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture store screenshots', (tester) async {
    FlavorConfig.flavor = Flavor.dev;
    await bootstrap();
    await tester.pump(const Duration(seconds: 1));

    // ── 1. Onboarding disclosure ───────────────────────────────────────
    await _waitFor(tester, find.text('I understand'));
    await _shoot(binding, tester, '01_onboarding');
    await tester.tap(find.text('I understand'));

    // ── 2. Home (logged out) → open login sheet ────────────────────────
    await _waitFor(tester, find.text('Log in to sync'));
    await tester.tap(find.text('Log in to sync'));

    // WebView runs Keycloak SSO; `ScreenshotMode` in login_screen.dart
    // auto-submits once the form loads. Signal for success is arrival
    // on the list-selection screen.
    await _waitFor(
      tester,
      find.text('Choose what to sync'),
      timeout: const Duration(minutes: 2),
    );

    // ── 3. List selection ─────────────────────────────────────────────
    await _shoot(binding, tester, '02_list_selection');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));

    // ── 4. Home (logged in, after sync populates enrollments) ──────────
    await _waitFor(tester, find.text('My Courses'));
    await _waitFor(
      tester,
      _byTypeName('_CourseTile'),
      timeout: _kSyncTimeout,
    );
    // Give the initial sync a beat to draw its progress bar in a clean
    // state (most stores reward "in progress" shots less than populated
    // ones, so we wait for at least one tile to have artwork).
    await tester.pump(const Duration(seconds: 2));
    await _shoot(binding, tester, '03_home');

    // ── 5. Course outline ─────────────────────────────────────────────
    await tester.tap(_byTypeName('_CourseTile').first);
    await _waitFor(
      tester,
      _byTypeName('_SequenceTile'),
      timeout: _kSyncTimeout,
    );
    await _shoot(binding, tester, '04_course_outline');

    // ── 6. Lecture / player ────────────────────────────────────────────
    await tester.tap(_byTypeName('_SequenceTile').first);
    // Chewie wraps the VideoPlayer; match on either class name so this
    // keeps working if we swap players later.
    await _waitFor(
      tester,
      find.byElementPredicate((e) {
        final t = e.widget.runtimeType.toString();
        return t == 'Chewie' || t == 'VideoPlayer';
      }),
      timeout: _kSyncTimeout,
    );
    // Let the first frame render + controls lay out.
    await tester.pump(const Duration(seconds: 3));
    await _shoot(binding, tester, '05_lecture');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
