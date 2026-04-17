import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/core/storage/app_database.dart';
import 'package:omnilect/features/progress/services/next_video_lecture_resolver.dart';

void main() {
  late AppDatabase db;
  late NextVideoLectureResolver resolver;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    resolver = NextVideoLectureResolver(db);
  });

  tearDown(() async {
    await db.close();
  });

  // ---------------------------------------------------------------------------
  // MITx helpers
  // ---------------------------------------------------------------------------

  Future<void> seedMitxOutline(
    String courseId,
    List<({String sectionId, String sectionTitle, List<String> sequenceIds})>
        sections,
  ) {
    final outline = {
      'course_key': courseId,
      'title': 'Test course',
      'course_start': null,
      'course_end': null,
      'outline': {
        'sections': [
          for (final s in sections)
            {
              'id': s.sectionId,
              'title': s.sectionTitle,
              'sequence_ids': s.sequenceIds,
              'start': null,
              'effective_start': null,
            },
        ],
        'sequences': {
          for (final s in sections)
            for (final seqId in s.sequenceIds)
              seqId: {'id': seqId, 'title': 'seq $seqId'},
        },
      },
    };
    return db.putOutline(courseId, jsonEncode(outline));
  }

  Future<void> seedSequence(
    String sequenceId,
    List<({String id, bool hasVideo})> verticals,
  ) async {
    final seq = {
      'items': [
        for (final v in verticals)
          {
            'id': v.id,
            'type': 'vertical',
            'page_title': v.id,
            'complete': false,
            'bookmarked': false,
            'path': '',
          },
      ],
    };
    await db.putSequence(sequenceId, jsonEncode(seq));
    for (final v in verticals) {
      final xblock = {
        'videos': v.hasVideo
            ? [
                {
                  'video_block_id': 'vb-${v.id}',
                  'mp4_url': 'https://cdn.example/${v.id}.mp4',
                  'hls_url': null,
                  'duration': 60.0,
                  'transcript_languages': <String, String>{},
                  'transcript_translation_url': null,
                }
              ]
            : <Map<String, dynamic>>[],
        'html_content': '<p>content</p>',
        'has_content': true,
      };
      await db.putXblock(v.id, jsonEncode(xblock));
    }
  }

  // ---------------------------------------------------------------------------
  // MITx tests
  // ---------------------------------------------------------------------------

  group('nextMitxVideoSequence', () {
    const courseId = 'course-v1:TEST+1+1';

    test('skips HTML-only sequences to next video-bearing one', () async {
      await seedMitxOutline(courseId, [
        (
          sectionId: 'sec1',
          sectionTitle: 'Section 1',
          sequenceIds: ['seq-a', 'seq-b', 'seq-c'],
        ),
      ]);
      await seedSequence('seq-a', [(id: 'v-a', hasVideo: true)]);
      await seedSequence('seq-b', [(id: 'v-b', hasVideo: false)]);
      await seedSequence('seq-c', [(id: 'v-c', hasVideo: true)]);

      final next = await resolver.nextMitxVideoSequence(
        courseId: courseId,
        fromSequenceId: 'seq-a',
      );
      expect(next, 'seq-c');
    });

    test('returns null when no later sequence has video', () async {
      await seedMitxOutline(courseId, [
        (
          sectionId: 'sec1',
          sectionTitle: 'Section 1',
          sequenceIds: ['seq-a', 'seq-b'],
        ),
      ]);
      await seedSequence('seq-a', [(id: 'v-a', hasVideo: true)]);
      await seedSequence('seq-b', [(id: 'v-b', hasVideo: false)]);

      final next = await resolver.nextMitxVideoSequence(
        courseId: courseId,
        fromSequenceId: 'seq-a',
      );
      expect(next, isNull);
    });

    test('walks across section boundaries', () async {
      await seedMitxOutline(courseId, [
        (
          sectionId: 'sec1',
          sectionTitle: 'Section 1',
          sequenceIds: ['seq-a'],
        ),
        (
          sectionId: 'sec2',
          sectionTitle: 'Section 2',
          sequenceIds: ['seq-b', 'seq-c'],
        ),
      ]);
      await seedSequence('seq-a', [(id: 'v-a', hasVideo: true)]);
      await seedSequence('seq-b', [(id: 'v-b', hasVideo: false)]);
      await seedSequence('seq-c', [(id: 'v-c', hasVideo: true)]);

      final next = await resolver.nextMitxVideoSequence(
        courseId: courseId,
        fromSequenceId: 'seq-a',
      );
      expect(next, 'seq-c');
    });

    test('returns null when fromSequenceId missing from outline', () async {
      await seedMitxOutline(courseId, [
        (
          sectionId: 'sec1',
          sectionTitle: 'Section 1',
          sequenceIds: ['seq-a'],
        ),
      ]);
      await seedSequence('seq-a', [(id: 'v-a', hasVideo: true)]);

      final next = await resolver.nextMitxVideoSequence(
        courseId: courseId,
        fromSequenceId: 'seq-missing',
      );
      expect(next, isNull);
    });

    test('returns null when course outline not cached', () async {
      final next = await resolver.nextMitxVideoSequence(
        courseId: courseId,
        fromSequenceId: 'seq-a',
      );
      expect(next, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // OCW tests
  // ---------------------------------------------------------------------------

  Future<void> seedOcwLectures(
    String courseId,
    List<({String lectureId, String? mp4Url, int order})> lectures,
  ) async {
    await db.into(db.cachedOcwCourses).insert(
          CachedOcwCoursesCompanion.insert(
            courseId: courseId,
            slug: 'slug',
            title: 'Course',
            courseNumber: 'TEST',
            description: '',
            cachedAt: DateTime.now(),
          ),
        );
    for (final l in lectures) {
      await db.into(db.cachedOcwLectures).insert(
            CachedOcwLecturesCompanion.insert(
              lectureId: l.lectureId,
              courseId: courseId,
              slug: l.lectureId,
              title: l.lectureId,
              sectionTitle: 'Video Lectures',
              sectionOrder: 0,
              lectureOrder: l.order,
              mp4Url: Value(l.mp4Url),
              cachedAt: DateTime.now(),
            ),
          );
    }
  }

  group('nextOcwVideoLecture', () {
    const courseId = 'ocw:test';

    test('skips lectures with null mp4Url', () async {
      await seedOcwLectures(courseId, [
        (lectureId: 'lec-1', mp4Url: 'a.mp4', order: 0),
        (lectureId: 'lec-2', mp4Url: null, order: 1),
        (lectureId: 'lec-3', mp4Url: 'b.mp4', order: 2),
      ]);

      final next = await resolver.nextOcwVideoLecture(
        courseId: courseId,
        fromLectureId: 'lec-1',
      );
      expect(next, 'lec-3');
    });

    test('returns null when no later video-bearing lecture', () async {
      await seedOcwLectures(courseId, [
        (lectureId: 'lec-1', mp4Url: 'a.mp4', order: 0),
        (lectureId: 'lec-2', mp4Url: null, order: 1),
      ]);

      final next = await resolver.nextOcwVideoLecture(
        courseId: courseId,
        fromLectureId: 'lec-1',
      );
      expect(next, isNull);
    });

    test('returns null when fromLectureId missing', () async {
      await seedOcwLectures(courseId, [
        (lectureId: 'lec-1', mp4Url: 'a.mp4', order: 0),
      ]);

      final next = await resolver.nextOcwVideoLecture(
        courseId: courseId,
        fromLectureId: 'lec-missing',
      );
      expect(next, isNull);
    });
  });
}
