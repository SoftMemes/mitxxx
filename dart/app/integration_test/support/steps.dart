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
  final deadline = DateTime.now().add(timeout);
  var i = 0;
  while (DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    if (++i % 20 == 0) {
      step('still waiting for ${label ?? finder}');
    }
  }
  throw TimeoutException(
    'Timed out after $timeout waiting for ${label ?? finder}',
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
  final deadline = DateTime.now().add(timeout);
  var i = 0;
  while (DateTime.now().isBefore(deadline)) {
    await $.tester.pump(const Duration(milliseconds: 250));
    if (predicate()) return;
    if (++i % 20 == 0) {
      step('still waiting for ${label ?? 'predicate'}');
    }
  }
  throw TimeoutException(
    'Timed out after $timeout waiting for ${label ?? 'predicate'}',
  );
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
/// second. Both pages render a single `android.widget.EditText` inside the
/// WebView, so `enterTextByIndex(0)` hits the right field on each step.
/// We then tap the submit button by its visible text ("Next" on the
/// username page, "Sign In" on the password page).
///
/// Only Android is supported — iOS parity is tracked in the spec's
/// open-follow-ups list.
Future<void> keycloakLogin(
  PatrolIntegrationTester $, {
  required String email,
  required String password,
}) async {
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'keycloakLogin currently supports Android only. '
      'iOS parity is tracked as a follow-up.',
    );
  }
  step('keycloak: entering username');
  // Give the WebView a moment to render before the automator reaches in.
  await $.tester.pump(const Duration(seconds: 2));
  // ignore: deprecated_member_use
  await $.native.enterTextByIndex(email, index: 0);
  // The visible button label differs between Keycloak's username and
  // password pages. Try a short list of likely labels before giving up —
  // this absorbs small upstream copy changes.
  await _tapKeycloakSubmit($, ['Next', 'Sign in', 'Sign In', 'Continue']);

  step('keycloak: entering password');
  await $.tester.pump(const Duration(seconds: 2));
  // ignore: deprecated_member_use
  await $.native.enterTextByIndex(password, index: 0);
  await _tapKeycloakSubmit($, ['Sign in', 'Sign In', 'Log in', 'Log In']);
  step('keycloak: submitted');
}

Future<void> _tapKeycloakSubmit(
  PatrolIntegrationTester $,
  List<String> candidates,
) async {
  for (final label in candidates) {
    try {
      // ignore: deprecated_member_use
      await $.native.tap(
        Selector(text: label),
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
