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
import 'dart:io';

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omnilect/flavor_config.dart';
import 'package:omnilect/main.dart';

const _kSyncTimeout = Duration(minutes: 5);
const _kInteractionTimeout = Duration(seconds: 30);

// ignore: avoid_print
void _step(String msg) => print('[screenshots] $msg');

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = _kInteractionTimeout,
  String? label,
}) async {
  final deadline = DateTime.now().add(timeout);
  var i = 0;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    if (++i % 20 == 0) {
      _step('still waiting for ${label ?? finder}');
    }
  }
  throw TimeoutException(
    'Timed out after $timeout waiting for ${label ?? finder}',
  );
}

Future<void> _shoot(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  _step('shooting $name');
  // Pump a few frames in case anything just animated in. We deliberately
  // don't `pumpAndSettle` — loading bars / progress indicators are
  // pumping continuously and pumpAndSettle would time out.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await binding.takeScreenshot(name);
  _step('shot $name ok');
}

Finder _byTypeName(String name) => find.byElementPredicate(
      (e) => e.widget.runtimeType.toString() == name,
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture store screenshots', (tester) async {
    _step('test started (platform=${Platform.operatingSystem})');
    FlavorConfig.flavor = Flavor.dev;
    await bootstrap();

    // bootstrap's zone runs async after returning — give runApp time to
    // schedule the first frame and render the disclaimer.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // Swallow framework errors. Real app code paths (sync, background
    // refreshes, Firebase, etc.) throw the occasional transient error,
    // particularly under emulator flakiness. We only care about getting
    // pixels on disk; log and continue.
    FlutterError.onError = (details) {
      _step('suppressed FlutterError: ${details.exception}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _step('suppressed platform error: $error');
      return true;
    };

    // Convert the Flutter surface ONCE for the whole test so
    // takeScreenshot can read pixels on Android. Calling it per-shot
    // leaves the surface in a half-converted state that breaks taps.
    // iOS treats this as a no-op.
    if (Platform.isAndroid) {
      _step('converting Flutter surface to image (Android)');
      await binding.convertFlutterSurfaceToImage();
    }

    // ── 1. Onboarding disclosure ───────────────────────────────────────
    _step('waiting for disclosure screen');
    await _waitFor(tester, find.text('I understand'),
        label: '"I understand" button');
    await _shoot(binding, tester, '01_onboarding');
    _step('tapping "I understand"');
    await tester.tap(find.text('I understand'));

    // ── 2. Home (logged out) → open login sheet ────────────────────────
    _step('waiting for logged-out home');
    await _waitFor(tester, find.text('Log in to sync'),
        label: '"Log in to sync" button');
    _step('tapping "Log in to sync"');
    await tester.tap(find.text('Log in to sync'));

    // WebView runs Keycloak SSO; `ScreenshotMode` in login_screen.dart
    // auto-submits once the form loads. Signal for success is arrival
    // on the list-selection screen.
    _step('waiting for list-selection screen (login round-trip)');
    await _waitFor(
      tester,
      find.text('Choose what to sync'),
      timeout: const Duration(minutes: 2),
      label: 'list-selection screen',
    );

    // ── 3. List selection ─────────────────────────────────────────────
    // The screen title renders before the list itself — wait for the
    // available-lists refresh to finish and at least one checkbox to
    // paint, otherwise `.first` throws Bad state: No element.
    _step('waiting for list checkboxes to render');
    await _waitFor(
      tester,
      find.byType(Checkbox),
      timeout: const Duration(minutes: 1),
      label: 'at least one list checkbox '
          '(account needs at least one MIT Learn list)',
    );
    await _shoot(binding, tester, '02_list_selection');
    _step('ticking first list + Continue');
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump(const Duration(milliseconds: 300));
    // The Continue button is disabled until a checkbox is ticked — give
    // the setState a pump so onPressed flips from null to a callback.
    await _waitFor(
      tester,
      find.widgetWithText(FilledButton, 'Continue'),
      label: 'Continue button',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));

    // ── 4. Home (logged in, after sync populates enrollments) ──────────
    _step('waiting for My Courses app bar');
    await _waitFor(tester, find.text('My Courses'));
    _step('waiting for at least one enrollment tile');
    await _waitFor(
      tester,
      _byTypeName('_CourseTile'),
      timeout: _kSyncTimeout,
      label: 'first course tile',
    );
    await tester.pump(const Duration(seconds: 2));
    await _shoot(binding, tester, '03_home');

    // ── 5. Course outline ─────────────────────────────────────────────
    _step('tapping first course');
    await tester.tap(_byTypeName('_CourseTile').first);
    await _waitFor(
      tester,
      _byTypeName('_SequenceTile'),
      timeout: _kSyncTimeout,
      label: 'first sequence tile',
    );
    await _shoot(binding, tester, '04_course_outline');

    // ── 6. Lecture / player ────────────────────────────────────────────
    // A sequence tile is only tappable-into-a-lecture once its sync
    // finishes — gray tiles just snackbar "Queued" on tap. Synced tiles
    // render a DownloadButton in their trailing area, so we wait for
    // one of those to appear and tap its containing _SequenceTile.
    // Find a sequence tile that (a) is a lecture (not a discussion
    // forum or other non-video item) and (b) has finished syncing.
    //   - Lecture-ness: title matches `Lecture <digit>` (MITx convention).
    //   - Synced-ness: a DownloadButton is rendered in the trailing row
    //     (only added after SequenceSyncStatus.synced).
    // We scope the DownloadButton match to _SequenceTile descendants so
    // the course-level AppBar DownloadButton doesn't satisfy the wait.
    final lectureTiles = find.ancestor(
      of: find.textContaining(RegExp(r'^Lecture\s*\d')),
      matching: _byTypeName('_SequenceTile'),
    );
    final syncedLectureButton = find.descendant(
      of: lectureTiles,
      matching: _byTypeName('DownloadButton'),
    );
    _step('waiting for a synced lecture sequence (can take several minutes)');
    await _waitFor(
      tester,
      syncedLectureButton,
      timeout: const Duration(minutes: 15),
      label: 'synced Lecture tile',
    );
    _step('tapping first synced lecture');
    final syncedTile = find.ancestor(
      of: syncedLectureButton.first,
      matching: _byTypeName('_SequenceTile'),
    );
    await tester.tap(syncedTile.first);
    await _waitFor(
      tester,
      find.byElementPredicate((e) {
        final t = e.widget.runtimeType.toString();
        return t == 'Chewie' || t == 'VideoPlayer';
      }),
      timeout: _kSyncTimeout,
      label: 'video player widget',
    );
    await tester.pump(const Duration(seconds: 3));
    await _shoot(binding, tester, '05_lecture');

    _step('done');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
