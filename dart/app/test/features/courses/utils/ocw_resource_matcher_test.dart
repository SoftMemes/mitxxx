import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_matcher.dart';

OcwLecture _lec(String cid, int n, String title, {String? slug}) => OcwLecture(
      id: '$cid/lecture-$n',
      slug: slug ?? 'lecture-$n-x',
      title: title,
      sectionTitle: 'Video Lectures',
      sectionOrder: 0,
      lectureOrder: n,
    );

OcwResource _res(String cid, String key, String title, {String? url}) =>
    OcwResource(
      id: '$cid::$key',
      type: OcwResourceType.lectureNotes,
      title: title,
      url: url ?? 'https://ocw.mit.edu/r/$key',
    );

void main() {
  group('extractLectureNumber', () {
    test('from "Lecture N" phrases', () {
      expect(extractLectureNumber('Lecture 14: The Visual Cortex'), 14);
      expect(extractLectureNumber('Lecture14'), 14);
      expect(extractLectureNumber('Lec 7'), 7);
      expect(extractLectureNumber('lecture 3'), 3);
    });

    test('from _l{NN} in URL path', () {
      expect(extractLectureNumber('mit9_13s19_l01'), 1);
      expect(extractLectureNumber('mit9_13s19_l14'), 14);
      expect(extractLectureNumber('/resources/mit9_13s19_l11/'), 11);
    });

    test('from trailing N.pdf', () {
      expect(extractLectureNumber('notes-3.pdf'), 3);
      expect(extractLectureNumber('handouts/lec-5.pdf'), 5);
    });

    test('from leading fileNum_', () {
      expect(extractLectureNumber('01_handout.pdf'), 1);
      expect(extractLectureNumber('12_slides.pdf'), 12);
    });

    test('Recitation N is not a lecture', () {
      expect(extractLectureNumber('Recitation 14: review'), isNull);
    });

    test('returns null when there is no number', () {
      expect(extractLectureNumber('Course Overview'), isNull);
      expect(extractLectureNumber('Introduction'), isNull);
    });
  });

  group('matchResourcesToLectures', () {
    test('one-to-one by lecture number', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 1, 'Lecture 1: Intro'), _lec(cid, 14, 'Lecture 14: Visual')];
      final resources = [
        _res(cid, 'n1', 'Lecture 1: Intro (PDF)'),
        _res(cid, 'n14', 'Lecture 14: Visual (PDF - 1.2MB)'),
      ];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, isEmpty);
      expect(result.lectures[0].resources, hasLength(1));
      expect(result.lectures[0].resources.first.lectureId, lectures[0].id);
      expect(result.lectures[1].resources, hasLength(1));
      expect(result.lectures[1].resources.first.lectureId, lectures[1].id);
    });

    test('uses URL _l{NN} when title lacks a number', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 11, 'Lecture 11: Development II')];
      final resources = [
        _res(cid, 'mit9_13s19_l11', '(Fallback) Notes',
            url: 'https://x/mit9_13s19_l11/'),
      ];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, isEmpty);
      expect(result.lectures.first.resources, hasLength(1));
    });

    test('Lecture 1 vs Lecture 10 do not collide', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 1, 'Lecture 1: Intro'), _lec(cid, 10, 'Lecture 10: Later')];
      final resources = [
        _res(cid, 'n10', 'Lecture 10: Later (PDF)'),
        _res(cid, 'n1', 'Lecture 1: Intro (PDF)'),
      ];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, isEmpty);
      expect(result.lectures[1].resources.first.title, startsWith('Lecture 10'));
      expect(result.lectures[0].resources.first.title, startsWith('Lecture 1:'));
    });

    test('Recitation N does not match Lecture N', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 14, 'Lecture 14: Visual')];
      final resources = [_res(cid, 'r14', 'Recitation 14 review')];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, hasLength(1));
      expect(result.lectures.first.resources, isEmpty);
    });

    test('orphaned when no matching lecture', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 1, 'Lecture 1: Intro')];
      final resources = [
        _res(cid, 'syllabus', 'Course Syllabus (PDF)'),
        _res(cid, 'bib', 'Full bibliography (PDF)'),
      ];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, hasLength(2));
      expect(result.lectures.first.resources, isEmpty);
    });

    test('prefix fallback when neither side has a number', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 1, 'Introduction to Neuroscience')];
      final resources = [_res(cid, 'intro', 'Introduction to Neuroscience — slides')];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, isEmpty);
      expect(result.lectures.first.resources, hasLength(1));
    });

    test('deterministic tie-breaking: first lecture wins', () {
      const cid = 'ocw:c';
      final lectures = [
        _lec(cid, 1, 'Lecture 1: Intro'),
        _lec(cid, 1, 'Lecture 1: Intro (dup)'),
      ];
      final resources = [_res(cid, 'n1', 'Lecture 1: Intro (PDF)')];
      final result = matchResourcesToLectures(lectures, resources);
      expect(result.orphans, isEmpty);
      expect(result.lectures[0].resources, hasLength(1));
      expect(result.lectures[1].resources, isEmpty);
    });

    test('input lectures list is not mutated (immutability contract)', () {
      const cid = 'ocw:c';
      final lectures = [_lec(cid, 1, 'Lecture 1: Intro')];
      final resources = [_res(cid, 'n1', 'Lecture 1: Intro (PDF)')];
      final result = matchResourcesToLectures(lectures, resources);
      // The original OcwLecture has no resources attached.
      expect(lectures.first.resources, isEmpty);
      // The returned lecture has the matched resource attached.
      expect(result.lectures.first.resources, hasLength(1));
    });
  });
}
