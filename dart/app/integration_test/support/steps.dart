import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

const kInteractionTimeout = Duration(seconds: 30);

// ignore: avoid_print
void step(String msg) => print('[patrol] $msg');

/// Prints a marker line consumed by `scripts/integration.sh`, which runs
/// `adb exec-out screencap` and writes the PNG to `screenshots/<subdir>/`.
/// The pump + 1.5 s sleep gives the shell pipeline time to spot the line
/// and capture before the UI moves on.
///
/// [subdir] is `raw` for store screenshots, `failures` for failure captures.
Future<void> captureScreenshot(
  PatrolIntegrationTester $,
  String name, {
  String subdir = 'raw',
}) async {
  // Flush any animated-in widgets before the host captures.
  for (var i = 0; i < 6; i++) {
    await $.tester.pump(const Duration(milliseconds: 100));
  }
  // ignore: avoid_print
  print('[patrol] SCREENSHOT $subdir $name');
  await stdout.flush();
  // Give the shell-side awk handler time to invoke adb screencap.
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  step('captured $name');
}

/// Polling wait on a Flutter finder with a label in timeout messages and
/// periodic progress logs for long-running waits.
Future<void> waitFor(
  PatrolIntegrationTester $,
  Finder finder, {
  Duration timeout = kInteractionTimeout,
  String? label,
}) async {
  final desc = label ?? finder.toString();
  step('waitFor: "$desc" (timeout=${_fmtDuration(timeout)})');
  final started = DateTime.now();
  final deadline = started.add(timeout);
  var i = 0;
  while (DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) {
      final elapsed = DateTime.now().difference(started);
      step('waitFor: "$desc" ✓ after ${_fmtDuration(elapsed)}');
      return;
    }
    if (++i % 20 == 0) {
      final elapsed = DateTime.now().difference(started);
      step('waitFor: still waiting for "$desc" '
          '(${_fmtDuration(elapsed)} / ${_fmtDuration(timeout)})');
    }
  }
  throw TimeoutException(
    'Timed out after ${_fmtDuration(timeout)} waiting for "$desc"',
  );
}

/// Polling wait on an arbitrary predicate — used for state-based assertions
/// that can't be expressed as a single Finder.
Future<void> waitUntil(
  PatrolIntegrationTester $,
  bool Function() predicate, {
  Duration timeout = kInteractionTimeout,
  String? label,
}) async {
  final desc = label ?? 'predicate';
  step('waitUntil: "$desc" (timeout=${_fmtDuration(timeout)})');
  final started = DateTime.now();
  final deadline = started.add(timeout);
  var i = 0;
  while (DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (predicate()) {
      final elapsed = DateTime.now().difference(started);
      step('waitUntil: "$desc" ✓ after ${_fmtDuration(elapsed)}');
      return;
    }
    if (++i % 20 == 0) {
      final elapsed = DateTime.now().difference(started);
      step('waitUntil: still waiting for "$desc" '
          '(${_fmtDuration(elapsed)} / ${_fmtDuration(timeout)})');
    }
  }
  throw TimeoutException(
    'Timed out after ${_fmtDuration(timeout)} waiting for "$desc"',
  );
}

String _fmtDuration(Duration d) {
  if (d.inMinutes >= 1) {
    final m = d.inMinutes;
    final s = d.inSeconds - m * 60;
    return '${m}m${s.toString().padLeft(2, '0')}s';
  }
  return '${d.inSeconds}s';
}

/// Matches widgets by the string name of their runtime type. Used to reach
/// private widgets like `_CourseTile`, `_SequenceTile`, and `DownloadButton`
/// without making them public just for test access.
Finder byTypeName(String name) => find.byElementPredicate(
      (e) => e.widget.runtimeType.toString() == name,
    );

/// Swallows transient `FlutterError.onError` / platform errors. Mirrors the
/// original screenshot harness so background sync / Firebase / emulator
/// flakiness doesn't fail the test. Assertion failures still propagate.
void suppressFrameworkErrors() {
  FlutterError.onError = (details) {
    step('suppressed FlutterError: ${details.exception}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    step('suppressed platform error: $error');
    return true;
  };
}

/// Runs [body] and captures a failure screenshot named `failure_<label>`
/// before rethrowing. Wraps the whole test body so any unexpected exception
/// leaves a PNG in `screenshots/failures/` for triage.
Future<T> runWithFailureScreenshot<T>(
  PatrolIntegrationTester $,
  String label,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } on Object catch (e) {
    step('test failed: $e');
    try {
      await captureScreenshot($, 'failure_$label', subdir: 'failures');
    } on Object catch (capErr) {
      step('failure-screenshot capture also failed: $capErr');
    }
    rethrow;
  }
}

/// Drives MIT's Keycloak SSO form via patrol native automation. MIT Keycloak
/// is a two-step login: username on the first page, then password on the
/// second. Each page renders a single text field inside a WebView —
/// `android.widget.EditText` on Android, an `XCUIElementTypeTextField` /
/// `XCUIElementTypeSecureTextField` on iOS. Patrol's `enterTextByIndex(0)`
/// targets exactly that element on both platforms. We then tap the submit
/// button by its visible text ("Next" on the username page, "Sign In" on
/// the password page).
Future<void> keycloakLogin(
  PatrolIntegrationTester $, {
  required String email,
  required String password,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    throw UnsupportedError(
      'keycloakLogin supports Android and iOS only '
      '(got ${Platform.operatingSystem}).',
    );
  }
  // Patrol's iOS automator scopes every native action to a bundleId
  // (Android auto-discovers the foreground app, iOS does not). For MITxxx
  // that's `app.omnilect.dev` (dev flavor) — matches `PRODUCT_BUNDLE_IDENTIFIER`
  // in `ios/Runner.xcodeproj/project.pbxproj`. Passing null on Android
  // keeps the existing auto-discovery behavior unchanged.
  final appId = Platform.isIOS ? 'app.omnilect.dev' : null;

  // iOS WKWebView first-paint on the simulator is slow — the Keycloak SSO
  // page can take 15–30 s before the email field becomes a real
  // XCUIElementTypeTextField. `enterTextByIndex`'s internal poll uses the
  // automator's default timeout (10 s); bump it on iOS so a slow load
  // doesn't fail the test. Android's WebView is fast enough that the
  // default is fine.
  final textEntryTimeout = Platform.isIOS
      ? const Duration(minutes: 1)
      : const Duration(seconds: 10);

  step('keycloak: entering username');
  // Give the WebView a moment to render before the automator reaches in.
  await $.tester.pump(Duration(seconds: Platform.isIOS ? 3 : 2));
  // ignore: deprecated_member_use
  await $.native.enterTextByIndex(
    email,
    index: 0,
    appId: appId,
    timeout: textEntryTimeout,
  );
  // MIT's Keycloak labels both submit buttons "Next" (username page +
  // password page). Extra fallbacks are kept for small upstream copy
  // changes.
  await _tapKeycloakSubmit(
    $,
    const ['Next', 'Continue', 'Sign in', 'Sign In'],
    appId: appId,
  );

  step('keycloak: entering password');
  await $.tester.pump(Duration(seconds: Platform.isIOS ? 3 : 2));
  // ignore: deprecated_member_use
  await $.native.enterTextByIndex(
    password,
    index: 0,
    appId: appId,
    timeout: textEntryTimeout,
  );
  await _tapKeycloakSubmit(
    $,
    const ['Next', 'Sign in', 'Sign In', 'Log in', 'Log In'],
    appId: appId,
  );
  step('keycloak: submitted');
}

Future<void> _tapKeycloakSubmit(
  PatrolIntegrationTester $,
  List<String> candidates, {
  String? appId,
}) async {
  for (final label in candidates) {
    try {
      // ignore: deprecated_member_use
      await $.native.tap(
        Selector(text: label),
        appId: appId,
        timeout: const Duration(seconds: 3),
      );
      step('keycloak: tapped "$label"');
      return;
    } on Object catch (_) {
      // Try next candidate.
    }
  }
  throw StateError(
    'Could not find a Keycloak submit button matching any of: $candidates',
  );
}
