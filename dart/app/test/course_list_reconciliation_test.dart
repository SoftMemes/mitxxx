import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/courses/models/list_source.dart';
import 'package:omnilect/features/courses/providers/available_lists_provider.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSelection(List<String> listIds) async {
    final now = DateTime.now();
    await db.replaceSelectedLists([
      for (final id in listIds)
        SelectedListsCompanion.insert(
          listId: id,
          source: id == kAllEnrolledListId
              ? ListSource.enrolled.storageValue
              : ListSource.learnMyList.storageValue,
          name: id,
          selectedAt: now,
        ),
    ]);
  }

  Future<void> seedCourseCache(String courseId) async {
    // Seed both cached_outlines and cached_course_sync so the course counts as
    // "locally known" for [getCoursesNotInSelection].
    await db.putOutline(courseId, '{"stub": true}');
    await db.putSyncSuccess(courseId, DateTime.now());
  }

  group('course-list reconciliation', () {
    test('rebuildMembershipForList inserts and replaces', () async {
      await seedSelection(['list-a']);
      await db.rebuildMembershipForList('list-a', ['c1', 'c2']);
      expect(await db.getCourseIdsInSelection(), {'c1', 'c2'});

      // Replace with different members — c2 remains, c3 added, c1 dropped.
      await db.rebuildMembershipForList('list-a', ['c2', 'c3']);
      expect(await db.getCourseIdsInSelection(), {'c2', 'c3'});
    });

    test('courseIdsInSelection unions across multiple lists', () async {
      await seedSelection(['list-a', 'list-b']);
      await db.rebuildMembershipForList('list-a', ['c1', 'c2']);
      await db.rebuildMembershipForList('list-b', ['c2', 'c3']);
      expect(await db.getCourseIdsInSelection(), {'c1', 'c2', 'c3'});
    });

    test('course kept when referenced by any remaining list', () async {
      await seedSelection(['list-a', 'list-b']);
      await db.rebuildMembershipForList('list-a', ['c1']);
      await db.rebuildMembershipForList('list-b', ['c1']);
      await seedCourseCache('c1');

      // Remove list-a — c1 should still be in selection via list-b.
      await db.rebuildMembershipForList('list-a', []);
      expect(await db.getCourseIdsInSelection(), {'c1'});
      expect(await db.getCoursesNotInSelection(), isEmpty);
    });

    test('course dropped when last list drops it', () async {
      await seedSelection(['list-a']);
      await db.rebuildMembershipForList('list-a', ['c1']);
      await seedCourseCache('c1');

      // Remove c1 from list-a.
      await db.rebuildMembershipForList('list-a', []);
      expect(await db.getCoursesNotInSelection(), {'c1'});
    });

    test(
      'coursesNotInSelection detects courses with cache but no membership',
      () async {
        // No selection at all, but cached course — should be in drop set.
        await seedCourseCache('orphan');
        expect(await db.getCoursesNotInSelection(), {'orphan'});
      },
    );

    test('deleteCourseCache wipes outline, sync, and membership rows',
        () async {
      await seedSelection(['list-a']);
      await db.rebuildMembershipForList('list-a', ['c1']);
      await seedCourseCache('c1');

      await db.deleteCourseCache('c1');

      final outlines =
          await (db.selectOnly(db.cachedOutlines)
                ..addColumns([db.cachedOutlines.courseId])
                ..where(db.cachedOutlines.courseId.equals('c1')))
              .get();
      expect(outlines, isEmpty);

      final syncRows =
          await (db.selectOnly(db.cachedCourseSync)
                ..addColumns([db.cachedCourseSync.courseId])
                ..where(db.cachedCourseSync.courseId.equals('c1')))
              .get();
      expect(syncRows, isEmpty);

      final members = await (db.select(db.courseListMemberships)
            ..where((t) => t.courseId.equals('c1')))
          .get();
      expect(members, isEmpty);
    });

    test('deleteCourseCache wipes course_positions for that course', () async {
      await db.upsertCoursePosition(
        courseId: 'c1',
        lectureId: 'seq-1',
        positionSeconds: 42,
      );
      await db.upsertCoursePosition(
        courseId: 'c2',
        lectureId: 'seq-2',
        positionSeconds: 7,
      );
      await db.deleteCourseCache('c1');
      expect(await db.getCoursePosition('c1'), isNull);
      // Other courses are unaffected.
      expect((await db.getCoursePosition('c2'))?.positionSeconds, 7);
    });

    test('clearAllAndGetDownloadPaths wipes all course_positions rows',
        () async {
      await db.upsertCoursePosition(
        courseId: 'c1',
        lectureId: 'seq-1',
        positionSeconds: 10,
      );
      await db.upsertCoursePosition(
        courseId: 'c2',
        lectureId: 'seq-2',
        positionSeconds: 20,
      );
      await db.clearAllAndGetDownloadPaths();
      expect(await db.getCoursePosition('c1'), isNull);
      expect(await db.getCoursePosition('c2'), isNull);
    });

    test(
      'pruneOrphanListData drops memberships for delisted lists',
      () async {
        await seedSelection(['list-a', 'list-b']);
        await db.rebuildMembershipForList('list-a', ['c1']);
        await db.rebuildMembershipForList('list-b', ['c2']);
        await seedCourseCache('c1');
        await seedCourseCache('c2');

        // User deselects list-a; selection now only contains list-b.
        await seedSelection(['list-b']);
        await db.pruneOrphanListData({'list-b'});

        // c1's membership should be gone, so c1 is in the drop set.
        expect(await db.getCourseIdsInSelection(), {'c2'});
        expect(await db.getCoursesNotInSelection(), {'c1'});
      },
    );

    test(
      'pruneOrphanListData with empty selection clears all memberships',
      () async {
        await seedSelection(['list-a']);
        await db.rebuildMembershipForList('list-a', ['c1', 'c2']);
        await seedCourseCache('c1');
        await seedCourseCache('c2');

        await db.replaceSelectedLists([]);
        await db.pruneOrphanListData(const <String>{});

        expect(await db.getCourseIdsInSelection(), isEmpty);
        expect(await db.getCoursesNotInSelection(), {'c1', 'c2'});
      },
    );

    test('replaceSelectedLists removes prior rows transactionally', () async {
      await seedSelection(['list-a', 'list-b', 'list-c']);
      expect((await db.getSelectedLists()).map((r) => r.listId).toSet(),
          {'list-a', 'list-b', 'list-c'});

      await seedSelection(['list-b']);
      expect((await db.getSelectedLists()).map((r) => r.listId).toSet(),
          {'list-b'});
    });
  });

  group('available lists cache', () {
    test('replaceAvailableLists transactionally replaces', () async {
      final now = DateTime.now();
      await db.replaceAvailableLists([
        AvailableListsCompanion.insert(
          listId: '1',
          source: ListSource.enrolled.storageValue,
          name: 'All enrolled',
          totalCourseCount: 3,
          fetchedAt: now,
        ),
        AvailableListsCompanion.insert(
          listId: '2',
          source: ListSource.learnMyList.storageValue,
          name: 'Favorites',
          totalCourseCount: 5,
          fetchedAt: now,
        ),
      ]);
      expect((await db.getAvailableLists()).length, 2);

      // Replacement with smaller set.
      await db.replaceAvailableLists([
        AvailableListsCompanion.insert(
          listId: '1',
          source: ListSource.enrolled.storageValue,
          name: 'All enrolled',
          totalCourseCount: 4,
          fetchedAt: now,
        ),
      ]);
      final remaining = await db.getAvailableLists();
      expect(remaining.length, 1);
      expect(remaining.single.totalCourseCount, 4);
    });
  });

  group('legacy migration-style behavior', () {
    test(
      'empty selection with cached enrollments → inserts all-enrolled',
      () async {
        // Simulate a pre-upgrade user: cached enrollments exist, selection is
        // empty. The migration function lives in its own provider; this test
        // asserts the DAO behavior it depends on.
        await db.putEnrollments(jsonEncode(const [
          {'id': 1},
        ]));
        expect(await db.getEnrollments(), isNotNull);
        expect(await db.getSelectedLists(), isEmpty);

        // Migration would call replaceSelectedLists with all-enrolled.
        await db.replaceSelectedLists([
          SelectedListsCompanion.insert(
            listId: kAllEnrolledListId,
            source: ListSource.enrolled.storageValue,
            name: 'All enrolled',
            selectedAt: DateTime.now(),
          ),
        ]);
        final rows = await db.getSelectedLists();
        expect(rows.single.listId, kAllEnrolledListId);
      },
    );
  });
}
