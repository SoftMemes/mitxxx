// Drives the app through onboarding → login → list selection → home →
// course outline → lecture, capturing a PNG at each stop. PNGs land in
// `dart/app/screenshots/raw/` — the shell wrapper (`scripts/integration.sh
// screenshots`) watches stdout for `[patrol] SCREENSHOT raw <name>` lines
// and runs `adb exec-out screencap -p > screenshots/raw/<name>.png`.
//
// Run via `scripts/integration.sh screenshots` (recommended — handles
// credentials, emulator, and screencap piping).
//
// Uses a real login + real sync. Point `.integration.env` at a dedicated
// MITx account.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/flavor_config.dart';
import 'package:omnilect/main.dart';
import 'package:patrol/patrol.dart';

import 'support/env.dart';
import 'support/steps.dart';

const _kSyncTimeout = Duration(minutes: 5);

void main() {
  patrolTest(
    'capture store screenshots',
    ($) async {
      await runWithFailureScreenshot($, 'screenshots', () async {
        step('test started (platform=${Platform.operatingSystem})');
        FlavorConfig.flavor = Flavor.dev;
        await bootstrap();

        // Give runApp time to schedule the first frame post-bootstrap.
        for (var i = 0; i < 20; i++) {
          await $.tester.pump(const Duration(milliseconds: 200));
        }

        suppressFrameworkErrors();

        // ── 1. Onboarding disclosure ────────────────────────────────────
        step('waiting for disclosure screen');
        await waitFor(
          $,
          find.text('I understand'),
          label: '"I understand" button',
        );
        await captureScreenshot($, '01_onboarding');
        step('tapping "I understand"');
        await $.tester.tap(find.text('I understand'));

        // ── 2. Logged-out home → open login sheet ───────────────────────
        step('waiting for logged-out home');
        await waitFor(
          $,
          find.text('Log in to sync'),
          label: '"Log in to sync" button',
        );
        step('tapping "Log in to sync"');
        await $.tester.tap(find.text('Log in to sync'));

        // ── 3. Keycloak SSO via native WebView ──────────────────────────
        await keycloakLogin(
          $,
          email: IntegrationEnv.email,
          password: IntegrationEnv.password,
        );

        step('waiting for list-selection screen (login round-trip)');
        await waitFor(
          $,
          find.text('Choose what to sync'),
          timeout: const Duration(minutes: 2),
          label: 'list-selection screen',
        );

        // ── 4. List selection ───────────────────────────────────────────
        step('waiting for list checkboxes to render');
        await waitFor(
          $,
          find.byType(Checkbox),
          timeout: const Duration(minutes: 1),
          label: 'at least one list checkbox '
              '(account needs at least one MIT Learn list)',
        );
        await captureScreenshot($, '02_list_selection');
        step('ticking list(s) + Continue');
        if (IntegrationEnv.hasListNames) {
          for (final name in IntegrationEnv.listNames) {
            await _tapListCheckbox($, name);
          }
        } else {
          // No specific list configured — just tick the first one so the
          // screenshot run can continue with whatever the test account has.
          await $.tester.tap(find.byType(Checkbox).first);
          await $.tester.pump(const Duration(milliseconds: 300));
        }
        await waitFor(
          $,
          find.widgetWithText(FilledButton, 'Continue'),
          label: 'Continue button',
        );
        await $.tester.tap(find.widgetWithText(FilledButton, 'Continue'));

        // ── 5. Home (logged in, post-sync) ──────────────────────────────
        step('waiting for My Courses app bar');
        await waitFor($, find.text('My Courses'));
        step('waiting for at least one enrollment tile');
        await waitFor(
          $,
          byTypeName('_CourseTile'),
          timeout: _kSyncTimeout,
          label: 'first course tile',
        );
        await $.tester.pump(const Duration(seconds: 2));
        await captureScreenshot($, '03_home');

        // ── 6. Course outline ───────────────────────────────────────────
        step('tapping first course');
        await $.tester.tap(byTypeName('_CourseTile').first);
        await waitFor(
          $,
          byTypeName('_SequenceTile'),
          timeout: _kSyncTimeout,
          label: 'first sequence tile',
        );
        await captureScreenshot($, '04_course_outline');

        // ── 7. Lecture / video player ───────────────────────────────────
        // A sequence is only tappable-into-a-lecture once its sync finishes
        // — unsynced tiles snackbar "Queued" on tap. Synced lecture tiles
        // render a DownloadButton in their trailing row, so wait for one
        // of those to appear and tap its containing _SequenceTile.
        final lectureTiles = find.ancestor(
          of: find.textContaining(RegExp(r'^Lecture\s*\d')),
          matching: byTypeName('_SequenceTile'),
        );
        final syncedLectureButton = find.descendant(
          of: lectureTiles,
          matching: byTypeName('DownloadButton'),
        );
        step('waiting for a synced lecture sequence (can take minutes)');
        await waitFor(
          $,
          syncedLectureButton,
          timeout: const Duration(minutes: 15),
          label: 'synced Lecture tile',
        );
        step('tapping first synced lecture');
        final syncedTile = find.ancestor(
          of: syncedLectureButton.first,
          matching: byTypeName('_SequenceTile'),
        );
        await $.tester.tap(syncedTile.first);
        await waitFor(
          $,
          find.byElementPredicate((e) {
            final t = e.widget.runtimeType.toString();
            return t == 'Chewie' || t == 'VideoPlayer';
          }),
          timeout: _kSyncTimeout,
          label: 'video player widget',
        );
        await $.tester.pump(const Duration(seconds: 3));
        await captureScreenshot($, '05_lecture');

        step('done');
      });
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

Future<void> _tapListCheckbox(PatrolIntegrationTester $, String name) async {
  final tile = find.ancestor(
    of: find.text(name),
    matching: find.byType(CheckboxListTile),
  );
  await waitFor($, tile, label: 'CheckboxListTile with text "$name"');
  await $.tester.tap(tile.first);
  await $.tester.pump(const Duration(milliseconds: 300));
}
