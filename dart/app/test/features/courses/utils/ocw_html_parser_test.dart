import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/utils/ocw_html_parser.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_matcher.dart';

const String _brainSlug = '9-13-the-human-brain-spring-2019';
const String _linAlgSlug = '18-06-linear-algebra-spring-2010';
const String _pySlug =
    '6-100l-introduction-to-cs-and-programming-using-python-fall-2022';

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

    test('6.100L detects lists/lecture-notes path (newer OCW template)', () {
      final home = parseCourseHome(_read(_pySlug, 'course_home.html'), _pySlug);
      expect(home.title, contains('Introduction to CS and Programming'));
      expect(home.courseNumber, '6.100l');
      // Newer courses ship lecture notes under /lists/lecture-notes/, not
      // /pages/lecture-notes/. parseCourseHome must pick it up anyway.
      expect(
        home.lectureNotesPath,
        '/courses/$_pySlug/lists/lecture-notes/',
      );
      expect(
        home.videoGalleryPath,
        '/courses/$_pySlug/video_galleries/lecture-videos/',
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

    test('6.100L gallery: lectures kept despite custom slug prefix', () {
      // 6.100L uses slugs like `6100l-lecture-1-version-2_mp4` instead of the
      // `lecture-N-...` prefix most courses use. Regression for a bug where
      // parseVideoGallery required the slug to start with "lecture".
      final lectures =
          parseVideoGallery(_read(_pySlug, 'video_gallery.html'), _pySlug);
      expect(lectures, isNotEmpty);
      // Every row's title should start with "Lecture N:".
      for (final l in lectures) {
        expect(l.title, matches(RegExp(r'^Lecture \d+:')));
        expect(l.slug, contains('lecture-'));
      }
      expect(lectures.first.slug, '6100l-lecture-1-version-2_mp4');
      expect(lectures.first.title, startsWith('Lecture 1:'));
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

    test('6.100L lecture page: relative MP4 URL is absolutised', () {
      // 6.100L hosts the MP4 directly on ocw.mit.edu with a root-relative
      // href. parseLecturePage must prepend the host so the download
      // pipeline (URL-as-primary-key) has a usable URL.
      final info = parseLecturePage(_read(_pySlug, 'lecture_1.html'));
      expect(info.title, startsWith('Lecture 1:'));
      expect(info.mp4Url, isNotNull);
      expect(info.mp4Url, startsWith('https://ocw.mit.edu/courses/$_pySlug/'));
      expect(info.mp4Url, endsWith('.mp4'));
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

    test('6.100L lecture-notes uses the .resource-list-title template', () {
      // Newer OCW template: each row has <a class="resource-list-title"
      // href="...pdf">Lecture N: Title</a>. parseLectureNotesPage prefers
      // that over the classic "(PDF" text filter.
      final resources = parseLectureNotesPage(
        _read(_pySlug, 'lecture_notes.html'),
        slug: _pySlug,
        courseId: 'ocw:$_pySlug',
      );
      expect(resources, isNotEmpty);
      final first = resources.first;
      expect(first.type, OcwResourceType.lectureNotes);
      expect(first.title, startsWith('Lecture 1:'));
      // Title is clean — no "pdf 832 kB" filesize junk from sibling links.
      expect(first.title, isNot(contains('pdf')));
      expect(first.title, isNot(contains('kB')));
      expect(first.url, endsWith('.pdf'));
      expect(first.url, startsWith('https://ocw.mit.edu/courses/$_pySlug/'));
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
