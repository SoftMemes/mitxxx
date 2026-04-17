import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/progress/services/next_video_lecture_resolver.dart';
import 'package:omnilect/features/progress/services/progress_tracker.dart';

/// Test-only resolver stub. Returns scripted answers without touching the DB.
class _FakeResolver implements NextVideoLectureResolver {
  String? mitxNext;
  String? ocwNext;

  @override
  AppDatabase get db => throw UnimplementedError();

  @override
  Future<String?> nextMitxVideoSequence({
    required String courseId,
    required String fromSequenceId,
  }) async =>
      mitxNext;

  @override
  Future<String?> nextOcwVideoLecture({
    required String courseId,
    required String fromLectureId,
  }) async =>
      ocwNext;
}

class _Clock {
  DateTime _now = DateTime.utc(2026);
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  late AppDatabase db;
  late _FakeResolver resolver;
  late _Clock clock;
  late ProgressTracker tracker;

  const courseId = 'course-v1:TEST+1+1';
  const lectureId = 'block-v1:TEST+1+1+type@sequential+block@a';

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    resolver = _FakeResolver();
    clock = _Clock();
    tracker = ProgressTracker(db: db, resolver: resolver, clock: clock.now);
  });

  tearDown(() async {
    await db.close();
  });

  Future<CoursePosition?> readRow() => db.getCoursePosition(courseId);

  group('recordPosition throttling', () {
    test('first call writes, rapid second call is coalesced', () async {
      await tracker.recordPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 10,
      );
      expect((await readRow())?.positionSeconds, 10);

      clock.advance(const Duration(seconds: 1));
      await tracker.recordPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 11,
      );
      expect((await readRow())?.positionSeconds, 10,
          reason: 'throttled within 5 s');
    });

    test('call after throttle window writes', () async {
      await tracker.recordPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 10,
      );
      clock.advance(const Duration(seconds: 6));
      await tracker.recordPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 20,
      );
      expect((await readRow())?.positionSeconds, 20);
    });
  });

  group('flushPosition', () {
    test('always writes regardless of throttle', () async {
      await tracker.recordPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 10,
      );
      clock.advance(const Duration(seconds: 1));
      await tracker.flushPosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 15,
      );
      expect((await readRow())?.positionSeconds, 15);
    });
  });

  group('recordCompletion', () {
    setUp(() async {
      await db.upsertCoursePosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 100,
      );
    });

    test('overwrites row with resolver next at position 0', () async {
      resolver.mitxNext = 'next-lecture';
      await tracker.recordCompletion(
        courseId: courseId,
        completedLectureId: lectureId,
      );
      final row = await readRow();
      expect(row, isNotNull);
      expect(row!.lectureId, 'next-lecture');
      expect(row.positionSeconds, 0);
    });

    test('deletes row when resolver returns null', () async {
      resolver.mitxNext = null;
      await tracker.recordCompletion(
        courseId: courseId,
        completedLectureId: lectureId,
      );
      expect(await readRow(), isNull);
    });

    test('no-op when tracked lectureId has already moved on', () async {
      resolver.mitxNext = 'should-not-be-used';
      await tracker.recordCompletion(
        courseId: courseId,
        completedLectureId: 'stale-other-lecture',
      );
      // Original row untouched.
      final row = await readRow();
      expect(row?.lectureId, lectureId);
      expect(row?.positionSeconds, 100);
    });

    test('uses OCW resolver when courseId has ocw: prefix', () async {
      const ocwCourseId = 'ocw:9-13';
      const ocwLectureId = 'ocw:9-13/lec-1';
      await db.upsertCoursePosition(
        courseId: ocwCourseId,
        lectureId: ocwLectureId,
        positionSeconds: 50,
      );
      resolver.ocwNext = 'ocw:9-13/lec-2';
      await tracker.recordCompletion(
        courseId: ocwCourseId,
        completedLectureId: ocwLectureId,
      );
      final row = await db.getCoursePosition(ocwCourseId);
      expect(row?.lectureId, 'ocw:9-13/lec-2');
      expect(row?.positionSeconds, 0);
    });
  });

  group('validateTrackedLecture', () {
    test('no-op when no row for course', () async {
      await tracker.validateTrackedLecture(courseId);
      expect(await readRow(), isNull);
    });

    test('deletes row when tracked MITx sequence missing from outline',
        () async {
      await db.upsertCoursePosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 30,
      );
      // Outline contains a different sequenceId — tracked one is stale.
      await db.putOutline(
        courseId,
        jsonEncode({
          'course_key': courseId,
          'title': 'x',
          'course_start': null,
          'course_end': null,
          'outline': {
            'sections': [
              {
                'id': 'sec',
                'title': 'Section',
                'sequence_ids': ['some-other-seq'],
                'start': null,
                'effective_start': null,
              },
            ],
            'sequences': <String, dynamic>{},
          },
        }),
      );
      await tracker.validateTrackedLecture(courseId);
      expect(await readRow(), isNull);
    });

    test('keeps row when tracked MITx sequence still in outline', () async {
      await db.upsertCoursePosition(
        courseId: courseId,
        lectureId: lectureId,
        positionSeconds: 30,
      );
      await db.putOutline(
        courseId,
        jsonEncode({
          'course_key': courseId,
          'title': 'x',
          'course_start': null,
          'course_end': null,
          'outline': {
            'sections': [
              {
                'id': 'sec',
                'title': 'Section',
                'sequence_ids': [lectureId],
                'start': null,
                'effective_start': null,
              },
            ],
            'sequences': <String, dynamic>{},
          },
        }),
      );
      await tracker.validateTrackedLecture(courseId);
      expect((await readRow())?.lectureId, lectureId);
    });
  });
}
