// End-to-end "blank-slate critical flow" integration test.
//
// Drives the app from a freshly-installed state through:
//   onboarding → login → list selection → initial sync →
//   open course → open lecture → play video → back to settings →
//   swap list selection → observe synced-list change.
//
// Run via `scripts/integration.sh flows` (handles `adb uninstall` and
// forwards `INTEGRATION_*` credentials from `.integration.env`).
//
// Spec: specs/app-integration-tests.md. Android emulator only; iOS is a
// follow-up. One `patrolTest`, no retries, stop on first failure.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/flavor_config.dart';
import 'package:omnilect/main.dart';
import 'package:patrol/patrol.dart';

import 'support/env.dart';
import 'support/steps.dart';

const _kSyncTimeout = Duration(minutes: 5);
const _kLectureSyncTimeout = Duration(minutes: 15);
const _kPostSwapTimeout = Duration(minutes: 5);
const _kLoginTimeout = Duration(minutes: 2);

void main() {
  patrolTest(
    'blank-slate critical flow',
    ($) async {
      await runWithFailureScreenshot($, 'blank_slate', () async {
        step('flow start (platform=${Platform.operatingSystem})');
        FlavorConfig.flavor = Flavor.dev;
        await bootstrap();

        for (var i = 0; i < 20; i++) {
          await $.tester.pump(const Duration(milliseconds: 200));
        }
        suppressFrameworkErrors();

        // ── 1. Onboarding disclosure ────────────────────────────────────
        step('step 1: onboarding disclosure');
        await waitFor(
          $,
          find.text('I understand'),
          label: '"I understand" button',
        );
        await $.tester.tap(find.text('I understand'));

        // ── 2. Logged-out home → login sheet ────────────────────────────
        step('step 2: open login sheet');
        await waitFor($, find.text('Log in to sync'));
        await $.tester.tap(find.text('Log in to sync'));

        // ── 3. Keycloak SSO via native WebView ──────────────────────────
        step('step 3: keycloak SSO');
        await keycloakLogin(
          $,
          email: IntegrationEnv.email,
          password: IntegrationEnv.password,
        );

        step('step 3: waiting for list-selection screen');
        await waitFor(
          $,
          find.text('Choose what to sync'),
          timeout: _kLoginTimeout,
          label: 'list-selection screen',
        );

        // ── 4. Initial list selection ───────────────────────────────────
        step('step 4: initial list selection');
        await waitFor(
          $,
          find.byType(Checkbox),
          timeout: const Duration(minutes: 1),
          label: 'at least one list checkbox',
        );
        for (final name in IntegrationEnv.listNames) {
          await _toggleList($, name, selected: true);
        }
        await waitFor($, find.widgetWithText(FilledButton, 'Continue'));
        await $.tester.tap(find.widgetWithText(FilledButton, 'Continue'));

        // ── 5. Initial sync + home baseline ─────────────────────────────
        step('step 5: waiting for My Courses + baseline tiles');
        await waitFor($, find.text('My Courses'), label: '"My Courses" app bar');
        await waitFor(
          $,
          byTypeName('_CourseTile'),
          timeout: _kSyncTimeout,
          label: 'first _CourseTile (sync populated)',
        );
        // Let late tiles paint in before snapshotting the baseline.
        await $.tester.pump(const Duration(seconds: 2));
        final baselineTiles = _currentCourseTileTitles($.tester);
        step('step 5: baseline tiles (${baselineTiles.length}) = '
            '${baselineTiles.toList()..sort()}');
        expect(baselineTiles, isNotEmpty, reason: 'baseline tile set empty');

        // ── 6. Open target course ───────────────────────────────────────
        step('step 6: opening course "${IntegrationEnv.courseTitle}"');
        expect(
          baselineTiles,
          contains(IntegrationEnv.courseTitle),
          reason:
              'INTEGRATION_COURSE_TITLE "${IntegrationEnv.courseTitle}" not '
              'among baseline tiles $baselineTiles — check env or account.',
        );
        final courseFinder = _courseTileByTitle(IntegrationEnv.courseTitle);
        await waitFor(
          $,
          courseFinder,
          label: '_CourseTile titled "${IntegrationEnv.courseTitle}"',
        );
        step('step 6: tapping _CourseTile');
        await $.tester.tap(courseFinder.first);
        await $.tester.pump(const Duration(milliseconds: 500));
        await waitFor(
          $,
          byTypeName('_SequenceTile'),
          timeout: _kSyncTimeout,
          label: 'first _SequenceTile in course outline',
        );
        final sequenceTitles = _visibleSequenceTileTitles($.tester);
        step('step 6: outline sequence tiles (${sequenceTitles.length}) = '
            '${sequenceTitles.take(8).toList()}'
            '${sequenceTitles.length > 8 ? " ..." : ""}');

        // ── 7. Open target lecture ──────────────────────────────────────
        step('step 7: waiting for "${IntegrationEnv.lectureTitle}" to finish '
            'sync (unsynced tiles snackbar "Queued" on tap)');
        final lectureTile = find.ancestor(
          of: find.text(IntegrationEnv.lectureTitle),
          matching: byTypeName('_SequenceTile'),
        );
        final syncedLectureButton = find.descendant(
          of: lectureTile,
          matching: byTypeName('DownloadButton'),
        );
        await waitFor(
          $,
          syncedLectureButton,
          timeout: _kLectureSyncTimeout,
          label: 'DownloadButton under _SequenceTile '
              '"${IntegrationEnv.lectureTitle}" (= synced)',
        );
        step('step 7: tapping lecture tile');
        await $.tester.tap(lectureTile.first);

        // ── 8. Video playback ───────────────────────────────────────────
        step('step 8: waiting for video player widget');
        await waitFor(
          $,
          find.byElementPredicate((e) {
            final t = e.widget.runtimeType.toString();
            return t == 'Chewie' || t == 'VideoPlayer';
          }),
          timeout: _kSyncTimeout,
          label: 'Chewie / VideoPlayer',
        );
        await $.tester.pump(const Duration(seconds: 3));

        // ── 9. Back to Settings → Courses ───────────────────────────────
        step('step 9: navigating back to Settings → Courses');
        // lecture → outline → home via the AppBar back buttons.
        await waitFor($, find.byType(BackButton), label: 'lecture back');
        await $.tester.tap(find.byType(BackButton).first);
        await waitFor(
          $,
          byTypeName('_SequenceTile'),
          label: 'outline (return)',
        );
        await waitFor($, find.byType(BackButton), label: 'outline back');
        await $.tester.tap(find.byType(BackButton).first);
        await waitFor($, find.text('My Courses'), label: 'home (return)');
        await $.tester.tap(find.byIcon(Icons.menu));
        await waitFor($, find.text('Settings'), label: 'settings screen');
        await $.tester.tap(find.widgetWithText(ListTile, 'Courses'));
        // Settings Courses screen shares the AppBar title "Courses" with the
        // ListTile we just tapped — wait for the Apply/Done button to know
        // we've actually landed on the screen.
        await waitFor(
          $,
          find.byType(FilledButton),
          timeout: const Duration(minutes: 1),
          label: 'Courses settings screen Apply/Done button',
        );

        // ── 10. Swap list selection ─────────────────────────────────────
        step('step 10: swapping list selection');
        for (final name in IntegrationEnv.listNames) {
          await _toggleList($, name, selected: false);
        }
        for (final name in IntegrationEnv.listNamesAlt) {
          await _toggleList($, name, selected: true);
        }
        // Button label is "Apply" once selection differs from the original.
        await waitFor($, find.widgetWithText(FilledButton, 'Apply'));
        await $.tester.tap(find.widgetWithText(FilledButton, 'Apply'));

        // ── 11. Observe synced-list change ──────────────────────────────
        step('step 11: waiting for tile set to change');
        await waitFor($, find.text('My Courses'));
        await waitUntil(
          $,
          () {
            final current = _currentCourseTileTitles($.tester);
            return current.isNotEmpty && !_setEquals(current, baselineTiles);
          },
          timeout: _kPostSwapTimeout,
          label: 'post-swap tile set != baseline',
        );
        final postSwapTiles = _currentCourseTileTitles($.tester);
        step('step 11: postSwapTiles = $postSwapTiles');
        expect(
          postSwapTiles,
          isNotEmpty,
          reason: 'post-swap tile set unexpectedly empty',
        );
        expect(
          _setEquals(postSwapTiles, baselineTiles),
          isFalse,
          reason: 'tile set unchanged after list swap',
        );
        expect(
          postSwapTiles.difference(baselineTiles),
          isNotEmpty,
          reason: 'alt list added no new courses (only removed) — '
              'pick an INTEGRATION_LIST_NAMES_ALT with distinct enrollments',
        );

        step('flow done');
      });
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

// Toggle a CheckboxListTile matched by its title text. Asserts the checkbox
// reaches the requested state after the tap so failures surface here rather
// than later when the Continue button's enabled state disagrees.
Future<void> _toggleList(
  PatrolIntegrationTester $,
  String name, {
  required bool selected,
}) async {
  final tile = find.ancestor(
    of: find.text(name),
    matching: find.byType(CheckboxListTile),
  );
  await waitFor($, tile, label: 'CheckboxListTile "$name"');
  final before = _isChecked($.tester, tile);
  if (before == selected) {
    step('list "$name" already ${selected ? "selected" : "unselected"}');
    return;
  }
  await $.tester.tap(tile.first);
  await $.tester.pump(const Duration(milliseconds: 400));
  final after = _isChecked($.tester, tile);
  expect(
    after,
    selected,
    reason: 'Tapping list "$name" did not toggle to selected=$selected',
  );
}

bool _isChecked(WidgetTester tester, Finder tileFinder) {
  final tile = tester.widget<CheckboxListTile>(tileFinder.first);
  return tile.value ?? false;
}

List<String> _visibleSequenceTileTitles(WidgetTester tester) {
  final titles = <String>[];
  for (final element in byTypeName('_SequenceTile').evaluate()) {
    final textFinder = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(Text),
    );
    final matches = textFinder.evaluate().toList();
    if (matches.isEmpty) continue;
    final widget = matches.first.widget as Text;
    final data = widget.data;
    if (data != null && data.isNotEmpty) titles.add(data);
  }
  return titles;
}

Set<String> _currentCourseTileTitles(WidgetTester tester) {
  final titles = <String>{};
  for (final element in byTypeName('_CourseTile').evaluate()) {
    // Title is the first descendant Text widget in each tile (the
    // `run.title` slot — see dart/app/lib/features/courses/screens/
    // home_screen.dart). `_OcwCourseTile` follows the same convention,
    // but this test scopes to MITx enrollments via `_CourseTile`.
    final textFinder = find.descendant(
      of: find.byWidget(element.widget),
      matching: find.byType(Text),
    );
    final matches = textFinder.evaluate().toList();
    if (matches.isEmpty) continue;
    final widget = matches.first.widget as Text;
    final data = widget.data;
    if (data != null && data.isNotEmpty) {
      titles.add(data);
    }
  }
  return titles;
}

bool _setEquals(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  for (final v in a) {
    if (!b.contains(v)) return false;
  }
  return true;
}

Finder _courseTileByTitle(String title) {
  return find.ancestor(
    of: find.text(title),
    matching: byTypeName('_CourseTile'),
  );
}
