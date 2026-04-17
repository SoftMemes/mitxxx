import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/utils/ocw_html_parser.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_matcher.dart';

const String _brainSlug = '9-13-the-human-brain-spring-2019';
const String _linAlgSlug = '18-06-linear-algebra-spring-2010';

String _read(String slug, String name) =>
    File('test/fixtures/ocw/$slug/$name').readAsStringSync();

void main() {
  group('parseCourseHome', () {
    test('brain fixture yields title + number + term + description + paths', () {
      final home = parseCourseHome(_read(_brainSlug, 'course_home.html'), _brainSlug);
      expect(home.title, 'The Human Brain');
      expect(home.courseNumber, '9.13');
      expect(home.term, 'Spring 2019');
      expect(home.description, startsWith('This course surveys the core perceptual'));
      expect(
        home.videoGalleryPath,
        '/courses/$_brainSlug/video_galleries/lecture-videos/',
      );
      expect(
        home.lectureNotesPath,
        '/courses/$_brainSlug/pages/lecture-notes/',
      );
    });

    test('linalg fixture has no lecture-notes page', () {
      final home = parseCourseHome(_read(_linAlgSlug, 'course_home.html'), _linAlgSlug);
      expect(home.title, 'Linear Algebra');
      expect(home.courseNumber, '18.06');
      expect(home.description, startsWith('This is a basic subject on matrix theory'));
      expect(
        home.videoGalleryPath,
        '/courses/$_linAlgSlug/video_galleries/video-lectures/',
      );
      expect(home.lectureNotesPath, isNull);
    });
  });

  group('parseVideoGallery', () {
    test('brain fixture is a flat list of 17 lectures', () {
      final lectures =
          parseVideoGallery(_read(_brainSlug, 'video_gallery.html'), _brainSlug);
      expect(lectures, hasLength(17));
      expect(lectures.first.slug, 'lecture-1-introduction');
      expect(lectures.first.title, startsWith('Lecture 1:'));
      for (final l in lectures) {
        expect(l.slug, startsWith('lecture-'));
      }
    });

    test('linalg fixture has 35 lectures ending with lecture-34', () {
      final lectures =
          parseVideoGallery(_read(_linAlgSlug, 'video_gallery.html'), _linAlgSlug);
      expect(lectures, hasLength(35));
      expect(lectures.last.slug, startsWith('lecture-34-'));
    });
  });

  group('parseLecturePage', () {
    test('brain lecture 1 extracts archive.org MP4 and title from <title>', () {
      final info = parseLecturePage(_read(_brainSlug, 'lecture_1.html'));
      expect(info.title, startsWith('Lecture 1:'));
      expect(
        info.mp4Url,
        'https://archive.org/download/MIT9.13S19/MIT9_13S19_lec01_300k.mp4',
      );
      expect(info.durationSeconds, isNull);
    });

    test('linalg lecture 1 extracts http:// archive.org MP4', () {
      final info = parseLecturePage(_read(_linAlgSlug, 'lecture_1.html'));
      expect(info.title, startsWith('Lecture 1:'));
      expect(info.mp4Url, 'http://www.archive.org/download/MIT18.06S05_MP4/01.mp4');
    });

    test('YouTube iframe is never selected as the MP4', () {
      final info = parseLecturePage(_read(_brainSlug, 'lecture_1.html'));
      expect(info.mp4Url, isNot(contains('youtube')));
    });
  });

  group('parseLectureNotesPage', () {
    test('brain lecture-notes yields 17 PDFs of type lecture-notes', () {
      final resources = parseLectureNotesPage(
        _read(_brainSlug, 'lecture_notes.html'),
        slug: _brainSlug,
        courseId: 'ocw:$_brainSlug',
      );
      expect(resources, hasLength(17));
      final sample = resources.first;
      expect(sample.type, OcwResourceType.lectureNotes);
      expect(sample.title, 'Lecture 1: Introduction');
      expect(sample.url, startsWith('https://ocw.mit.edu/courses/'));
      // Title strips the "(PDF)" / "(PDF - 1.6MB)" suffix OCW appends.
      expect(sample.title, isNot(contains('(PDF')));
    });
  });

  group('end-to-end (buildCourseFromFixtures)', () {
    test('brain happy-path: 17 matched lectures, zero orphans', () {
      final course = _buildCourseFromFixtures(_brainSlug);
      expect(course.id, 'ocw:$_brainSlug');
      expect(course.title, 'The Human Brain');
      expect(course.courseNumber, '9.13');
      expect(course.sections, hasLength(1));
      expect(course.sections.first.title, 'Video Lectures');
      expect(course.sections.first.lectures, hasLength(17));
      expect(course.orphanResources, isEmpty);
      final lec1 = course.sections.first.lectures.first;
      expect(
        lec1.mp4Url,
        'https://archive.org/download/MIT9.13S19/MIT9_13S19_lec01_300k.mp4',
      );
      expect(lec1.resources, hasLength(1));
      // Every matched resource points to the correct lecture's _l{NN} slug.
      for (final lec in course.sections.first.lectures) {
        final n = int.parse(
          lec.title.split(':').first.replaceAll(RegExp(r'\D'), ''),
        );
        final expected = '_l${n.toString().padLeft(2, '0')}';
        for (final r in lec.resources) {
          expect(r.url, contains(expected),
              reason: 'mismatch ${lec.title} -> ${r.url}');
        }
      }
    });

    test('linalg: no notes page means zero resources', () {
      final course = _buildCourseFromFixtures(_linAlgSlug);
      expect(course.courseNumber, '18.06');
      expect(course.sections.first.lectures, hasLength(35));
      expect(course.orphanResources, isEmpty);
      for (final lec in course.sections.first.lectures) {
        expect(lec.resources, isEmpty);
      }
    });
  });
}

/// Fixture-backed orchestrator that mirrors the Python reference's
/// `build_course_from_fixtures`. Only used by this test file — the live
/// equivalent is `OcwCourseFetcher` (Phase 2b).
OcwCourse _buildCourseFromFixtures(String slug) {
  final courseId = 'ocw:$slug';
  final home = parseCourseHome(
    File('test/fixtures/ocw/$slug/course_home.html').readAsStringSync(),
    slug,
  );

  final lectures = <OcwLecture>[];
  final galleryFile = File('test/fixtures/ocw/$slug/video_gallery.html');
  if (galleryFile.existsSync()) {
    final refs = parseVideoGallery(galleryFile.readAsStringSync(), slug);
    for (var i = 0; i < refs.length; i++) {
      final ref = refs[i];
      // Only lecture_1.html is committed per fixture directory; others have no
      // fixture so mp4Url stays null. That's enough to exercise the orchestrator.
      String? mp4Url;
      var title = ref.title;
      if (ref.slug.startsWith('lecture-1-')) {
        final info = parseLecturePage(
          File('test/fixtures/ocw/$slug/lecture_1.html').readAsStringSync(),
        );
        mp4Url = info.mp4Url;
        if (title.isEmpty) title = info.title;
      }
      lectures.add(OcwLecture(
        id: '$courseId/${ref.slug}',
        slug: ref.slug,
        title: title,
        sectionTitle: 'Video Lectures',
        sectionOrder: 0,
        lectureOrder: i,
        mp4Url: mp4Url,
      ));
    }
  }

  final resources = <OcwResource>[];
  final notesFile = File('test/fixtures/ocw/$slug/lecture_notes.html');
  if (notesFile.existsSync()) {
    resources.addAll(parseLectureNotesPage(
      notesFile.readAsStringSync(),
      slug: slug,
      courseId: courseId,
    ));
  }

  final match = matchResourcesToLectures(lectures, resources);
  return OcwCourse(
    id: courseId,
    slug: slug,
    title: home.title,
    courseNumber: home.courseNumber,
    description: home.description,
    sections: lectures.isEmpty
        ? const []
        : [OcwSection(title: 'Video Lectures', order: 0, lectures: match.lectures)],
    orphanResources: match.orphans,
  );
}
